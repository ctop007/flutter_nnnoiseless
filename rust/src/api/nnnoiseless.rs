use anyhow::{Context, Result};
use dasp::interpolate::sinc::Sinc;
use dasp::ring_buffer::Fixed;
use dasp::{signal, Signal};
use hound::{WavReader, WavSpec, WavWriter};
use nnnoiseless::{DenoiseState, RnnModel};
use once_cell::sync::Lazy;
use std::path::Path;

pub(crate) const FRAME_SIZE: usize = DenoiseState::FRAME_SIZE;
pub(crate) const TARGET_SAMPLE_RATE: u32 = 48_000;

static MODEL: Lazy<RnnModel> = Lazy::new(RnnModel::default);

struct LinearResampler {
    step: f64,
    buffer: Vec<f32>,
    position: f64,
}

impl LinearResampler {
    fn new(input_rate: u32, output_rate: u32) -> Self {
        Self {
            step: input_rate as f64 / output_rate as f64,
            buffer: Vec::new(),
            position: 0.0,
        }
    }

    fn process(&mut self, input: &[f32]) -> Vec<f32> {
        if input.is_empty() {
            return Vec::new();
        }

        self.buffer.extend_from_slice(input);
        self.emit_available()
    }

    fn flush(&mut self, tail_sample: f32) -> Vec<f32> {
        if self.buffer.is_empty() {
            return Vec::new();
        }

        self.buffer.push(tail_sample);
        let output = self.emit_available();
        self.buffer.clear();
        self.buffer.push(tail_sample);
        self.position = 0.0;
        output
    }

    fn emit_available(&mut self) -> Vec<f32> {
        let mut output = Vec::new();

        while self.position + 1.0 < self.buffer.len() as f64 {
            let index = self.position.floor() as usize;
            let fraction = (self.position - index as f64) as f32;
            let a = self.buffer[index];
            let b = self.buffer[index + 1];
            output.push(a + (b - a) * fraction);
            self.position += self.step;
        }

        let consumed = self.position.floor() as usize;
        if consumed > 0 {
            self.buffer.drain(0..consumed);
            self.position -= consumed as f64;
        }

        output
    }
}

pub(crate) struct DenoiseStream {
    input_resampler: Option<LinearResampler>,
    output_resampler: Option<LinearResampler>,
    denoiser: Box<DenoiseState<'static>>,
    pending_target_samples: Vec<f32>,
    pending_offset: usize,
    first_frame_seen: bool,
}

impl DenoiseStream {
    pub(crate) fn new(input_sample_rate: u32, num_channels: u32) -> Result<Self> {
        if input_sample_rate == 0 {
            anyhow::bail!("input_sample_rate must be greater than 0");
        }
        if num_channels != 1 {
            anyhow::bail!("Only mono streaming audio is supported");
        }

        Ok(Self {
            input_resampler: (input_sample_rate != TARGET_SAMPLE_RATE)
                .then(|| LinearResampler::new(input_sample_rate, TARGET_SAMPLE_RATE)),
            output_resampler: (input_sample_rate != TARGET_SAMPLE_RATE)
                .then(|| LinearResampler::new(TARGET_SAMPLE_RATE, input_sample_rate)),
            denoiser: DenoiseState::with_model(&MODEL),
            pending_target_samples: Vec::new(),
            pending_offset: 0,
            first_frame_seen: false,
        })
    }

    pub(crate) fn process_chunk(&mut self, input: &[u8]) -> Result<Vec<u8>> {
        let samples = decode_pcm16(input)?;
        let target_rate_samples = match &mut self.input_resampler {
            Some(resampler) => resampler.process(&samples),
            None => samples,
        };

        self.pending_target_samples
            .extend_from_slice(&target_rate_samples);

        let denoised = self.process_pending_frames(false);
        let output_samples = match &mut self.output_resampler {
            Some(resampler) => resampler.process(&denoised),
            None => denoised,
        };

        Ok(encode_pcm16(&output_samples))
    }

    pub(crate) fn flush(&mut self) -> Result<Vec<u8>> {
        if let Some(resampler) = &mut self.input_resampler {
            let target_tail = resampler.flush(0.0);
            self.pending_target_samples.extend_from_slice(&target_tail);
        }

        let mut denoised = self.process_pending_frames(true);
        if let Some(resampler) = &mut self.output_resampler {
            let mut output = resampler.process(&denoised);
            output.extend(resampler.flush(0.0));
            denoised = output;
        }

        Ok(encode_pcm16(&denoised))
    }

    fn process_pending_frames(&mut self, flush_partial_frame: bool) -> Vec<f32> {
        let mut denoised = Vec::new();

        while self.pending_len() >= FRAME_SIZE {
            let start = self.pending_offset;
            let end = start + FRAME_SIZE;
            let mut output_frame = vec![0.0f32; FRAME_SIZE];
            self.denoiser
                .process_frame(&mut output_frame, &self.pending_target_samples[start..end]);
            self.pending_offset = end;

            if self.first_frame_seen {
                denoised.extend_from_slice(&output_frame);
            } else {
                self.first_frame_seen = true;
            }

            self.compact_pending();
        }

        if flush_partial_frame && self.pending_len() > 0 {
            let remaining = self.pending_len();
            let mut input_frame = vec![0.0f32; FRAME_SIZE];
            let start = self.pending_offset;
            let end = self.pending_target_samples.len();
            input_frame[..remaining].copy_from_slice(&self.pending_target_samples[start..end]);

            let mut output_frame = vec![0.0f32; FRAME_SIZE];
            self.denoiser.process_frame(&mut output_frame, &input_frame);
            self.pending_target_samples.clear();
            self.pending_offset = 0;

            if self.first_frame_seen {
                denoised.extend_from_slice(&output_frame[..remaining]);
            } else {
                self.first_frame_seen = true;
            }
        }

        denoised
    }

    fn pending_len(&self) -> usize {
        self.pending_target_samples
            .len()
            .saturating_sub(self.pending_offset)
    }

    fn compact_pending(&mut self) {
        if self.pending_offset == 0 {
            return;
        }

        if self.pending_offset >= self.pending_target_samples.len() {
            self.pending_target_samples.clear();
            self.pending_offset = 0;
            return;
        }

        if self.pending_offset >= FRAME_SIZE * 8 {
            self.pending_target_samples.drain(0..self.pending_offset);
            self.pending_offset = 0;
        }
    }
}

pub(crate) fn recommended_input_frame_bytes(input_sample_rate: u32, num_channels: u32) -> usize {
    if input_sample_rate == 0 || num_channels == 0 {
        return 0;
    }

    let samples = ((input_sample_rate as f64) / 100.0).round() as usize;
    samples * num_channels as usize * std::mem::size_of::<i16>()
}

fn decode_pcm16(input: &[u8]) -> Result<Vec<f32>> {
    if input.len() % std::mem::size_of::<i16>() != 0 {
        anyhow::bail!("PCM input must contain an even number of bytes");
    }

    Ok(input
        .chunks_exact(2)
        .map(|chunk| i16::from_le_bytes([chunk[0], chunk[1]]) as f32)
        .collect())
}

fn encode_pcm16(input: &[f32]) -> Vec<u8> {
    let mut bytes = Vec::with_capacity(input.len() * std::mem::size_of::<i16>());
    for sample in input {
        let clipped = sample.clamp(i16::MIN as f32, i16::MAX as f32) as i16;
        bytes.extend_from_slice(&clipped.to_le_bytes());
    }
    bytes
}

pub(crate) fn denoise_file(input_path_str: &str, output_path_str: &str) -> Result<()> {
    let input_path = Path::new(input_path_str);
    let output_path = Path::new(output_path_str);
    denoise_wav(input_path, output_path)
}

fn denoise_wav(input_path: &Path, output_path: &Path) -> Result<()> {
    let mut reader = WavReader::open(input_path)
        .with_context(|| format!("Failed to open input file: {:?}", input_path))?;
    let spec = reader.spec();

    let input_samples_interleaved: Vec<f32> = reader
        .samples::<i16>()
        .map(|sample| sample.unwrap() as f32)
        .collect();

    if input_samples_interleaved.is_empty() {
        anyhow::bail!("Input file is empty.");
    }

    let num_channels = spec.channels as usize;
    let mut channel_buffers =
        vec![Vec::with_capacity(input_samples_interleaved.len() / num_channels); num_channels];

    for (index, sample) in input_samples_interleaved.iter().enumerate() {
        channel_buffers[index % num_channels].push(*sample);
    }

    let resampled_channels = if spec.sample_rate != TARGET_SAMPLE_RATE {
        channel_buffers
            .into_iter()
            .map(|channel_data| {
                let signal = signal::from_iter(channel_data);
                let sinc = Sinc::new(Fixed::from([0.0; 256]));
                signal
                    .from_hz_to_hz(sinc, spec.sample_rate as f64, TARGET_SAMPLE_RATE as f64)
                    .until_exhausted()
                    .collect::<Vec<f32>>()
            })
            .collect::<Vec<_>>()
    } else {
        channel_buffers
    };

    let mut denoisers: Vec<Box<DenoiseState>> = (0..num_channels)
        .map(|_| DenoiseState::with_model(&MODEL))
        .collect();

    let num_samples_per_channel = resampled_channels.first().map_or(0, Vec::len);
    let mut cleaned_channels = vec![Vec::with_capacity(num_samples_per_channel); num_channels];

    for frame_start in (0..num_samples_per_channel).step_by(FRAME_SIZE) {
        for channel in 0..num_channels {
            let frame_end = (frame_start + FRAME_SIZE).min(num_samples_per_channel);
            let input_slice = &resampled_channels[channel][frame_start..frame_end];

            let mut input_frame = vec![0.0f32; FRAME_SIZE];
            input_frame[..input_slice.len()].copy_from_slice(input_slice);

            let mut output_frame = vec![0.0f32; FRAME_SIZE];
            denoisers[channel].process_frame(&mut output_frame, &input_frame);
            cleaned_channels[channel].extend_from_slice(&output_frame[..(frame_end - frame_start)]);
        }
    }

    let mut output_samples_interleaved = vec![0.0f32; cleaned_channels[0].len() * num_channels];
    for index in 0..cleaned_channels[0].len() {
        for channel in 0..num_channels {
            output_samples_interleaved[index * num_channels + channel] =
                cleaned_channels[channel][index];
        }
    }

    let output_spec = WavSpec {
        channels: spec.channels,
        sample_rate: TARGET_SAMPLE_RATE,
        bits_per_sample: 16,
        sample_format: hound::SampleFormat::Int,
    };

    let mut writer = WavWriter::create(output_path, output_spec)?;
    for sample in output_samples_interleaved {
        let clipped = sample.clamp(i16::MIN as f32, i16::MAX as f32) as i16;
        writer.write_sample(clipped)?;
    }
    writer.finalize()?;

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{recommended_input_frame_bytes, DenoiseStream, TARGET_SAMPLE_RATE};

    #[test]
    fn recommended_stream_chunk_is_10ms_of_pcm16() {
        assert_eq!(recommended_input_frame_bytes(48_000, 1), 960);
        assert_eq!(recommended_input_frame_bytes(16_000, 1), 320);
    }

    #[test]
    fn stream_flush_is_empty_for_no_input() {
        let mut stream = DenoiseStream::new(TARGET_SAMPLE_RATE, 1).unwrap();
        assert!(stream.flush().unwrap().is_empty());
    }
}
