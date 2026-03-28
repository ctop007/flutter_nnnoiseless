use crate::api::nnnoiseless::{
    denoise_file, recommended_input_frame_bytes, DenoiseStream, FRAME_SIZE, TARGET_SAMPLE_RATE,
};
use std::cell::RefCell;
use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int};
use std::ptr;

const ERROR_CODE_SUCCESS: c_int = 0;
const ERROR_CODE_FAILURE: c_int = 1;

thread_local! {
    static LAST_ERROR: RefCell<Option<String>> = const { RefCell::new(None) };
}

#[repr(C)]
pub struct FfiByteBuffer {
    pub ptr: *mut u8,
    pub len: usize,
    pub code: c_int,
}

fn set_last_error(message: impl Into<String>) {
    LAST_ERROR.with(|slot| {
        *slot.borrow_mut() = Some(message.into());
    });
}

fn clear_last_error() {
    LAST_ERROR.with(|slot| {
        *slot.borrow_mut() = None;
    });
}

fn ok_buffer(mut data: Vec<u8>) -> FfiByteBuffer {
    let buffer = FfiByteBuffer {
        ptr: data.as_mut_ptr(),
        len: data.len(),
        code: ERROR_CODE_SUCCESS,
    };
    std::mem::forget(data);
    buffer
}

fn error_buffer(message: impl Into<String>) -> FfiByteBuffer {
    set_last_error(message);
    FfiByteBuffer {
        ptr: ptr::null_mut(),
        len: 0,
        code: ERROR_CODE_FAILURE,
    }
}

unsafe fn string_from_ptr<'a>(value: *const c_char, label: &str) -> anyhow::Result<&'a str> {
    if value.is_null() {
        anyhow::bail!("{label} must not be null");
    }

    // SAFETY: The caller must pass a valid, null-terminated C string.
    unsafe { CStr::from_ptr(value) }
        .to_str()
        .map_err(|_| anyhow::anyhow!("{label} must be valid UTF-8"))
}

#[no_mangle]
pub extern "C" fn nnnoiseless_target_sample_rate() -> u32 {
    TARGET_SAMPLE_RATE
}

#[no_mangle]
pub extern "C" fn nnnoiseless_frame_size() -> usize {
    FRAME_SIZE
}

#[no_mangle]
pub extern "C" fn nnnoiseless_stream_recommended_input_bytes(
    input_sample_rate: u32,
    num_channels: u32,
) -> usize {
    recommended_input_frame_bytes(input_sample_rate, num_channels)
}

#[no_mangle]
pub unsafe extern "C" fn nnnoiseless_denoise_file(
    input_path: *const c_char,
    output_path: *const c_char,
) -> c_int {
    clear_last_error();

    let result = (|| {
        let input_path = unsafe { string_from_ptr(input_path, "input_path") }?;
        let output_path = unsafe { string_from_ptr(output_path, "output_path") }?;
        denoise_file(input_path, output_path)
    })();

    match result {
        Ok(()) => ERROR_CODE_SUCCESS,
        Err(err) => {
            set_last_error(err.to_string());
            ERROR_CODE_FAILURE
        }
    }
}

#[no_mangle]
pub extern "C" fn nnnoiseless_stream_create(
    input_sample_rate: u32,
    num_channels: u32,
) -> *mut DenoiseStream {
    clear_last_error();

    match DenoiseStream::new(input_sample_rate, num_channels) {
        Ok(stream) => Box::into_raw(Box::new(stream)),
        Err(err) => {
            set_last_error(err.to_string());
            ptr::null_mut()
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn nnnoiseless_stream_process(
    stream: *mut DenoiseStream,
    input_ptr: *const u8,
    input_len: usize,
) -> FfiByteBuffer {
    clear_last_error();

    if stream.is_null() {
        return error_buffer("stream must not be null");
    }

    let input = if input_len == 0 {
        &[]
    } else if input_ptr.is_null() {
        return error_buffer("input_ptr must not be null when input_len > 0");
    } else {
        // SAFETY: The caller guarantees that the byte buffer is valid for `input_len` bytes.
        unsafe { std::slice::from_raw_parts(input_ptr, input_len) }
    };

    // SAFETY: The caller provides a valid stream handle created by `nnnoiseless_stream_create`.
    match unsafe { &mut *stream }.process_chunk(input) {
        Ok(bytes) => ok_buffer(bytes),
        Err(err) => error_buffer(err.to_string()),
    }
}

#[no_mangle]
pub unsafe extern "C" fn nnnoiseless_stream_flush(stream: *mut DenoiseStream) -> FfiByteBuffer {
    clear_last_error();

    if stream.is_null() {
        return error_buffer("stream must not be null");
    }

    // SAFETY: The caller provides a valid stream handle created by `nnnoiseless_stream_create`.
    match unsafe { &mut *stream }.flush() {
        Ok(bytes) => ok_buffer(bytes),
        Err(err) => error_buffer(err.to_string()),
    }
}

#[no_mangle]
pub unsafe extern "C" fn nnnoiseless_stream_destroy(stream: *mut DenoiseStream) {
    if stream.is_null() {
        return;
    }

    // SAFETY: Ownership is transferred back from Dart exactly once on close/finalize.
    drop(unsafe { Box::from_raw(stream) });
}

#[no_mangle]
pub unsafe extern "C" fn nnnoiseless_buffer_free(ptr: *mut u8, len: usize) {
    if ptr.is_null() {
        return;
    }

    // SAFETY: The pointer and length originate from `ok_buffer`.
    drop(unsafe { Vec::from_raw_parts(ptr, len, len) });
}

#[no_mangle]
pub extern "C" fn nnnoiseless_last_error_message() -> *mut c_char {
    LAST_ERROR.with(|slot| {
        let Some(message) = slot.borrow().clone() else {
            return ptr::null_mut();
        };

        match CString::new(message) {
            Ok(message) => message.into_raw(),
            Err(_) => ptr::null_mut(),
        }
    })
}

#[no_mangle]
pub unsafe extern "C" fn nnnoiseless_string_free(ptr: *mut c_char) {
    if ptr.is_null() {
        return;
    }

    // SAFETY: The pointer originates from `CString::into_raw`.
    drop(unsafe { CString::from_raw(ptr) });
}
