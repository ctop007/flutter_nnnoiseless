#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint flutter_nnnoiseless.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  prebuilt_xcframework = File.expand_path('Frameworks/hzh_noise.xcframework', __dir__)
  use_prebuilt_ios = File.directory?(prebuilt_xcframework)

  s.name             = 'flutter_nnnoiseless'
  s.version          = '0.0.1'
  s.summary          = 'A new Flutter FFI plugin project.'
  s.description      = <<-DESC
A new Flutter FFI plugin project.
                       DESC
  s.homepage         = 'https://www,antonkarpenko.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Anton Karpenko' => 'kapraton@gmail.com' }

  # This will ensure the source files in Classes/ are included in the native
  # builds of apps using this FFI plugin. Podspec does not support relative
  # paths, so Classes contains a forwarder C file that relatively imports
  # `../src/*` so that the C sources can be shared among all target platforms.
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '11.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'

  if use_prebuilt_ios
    s.vendored_frameworks = 'Frameworks/hzh_noise.xcframework'
    s.preserve_paths = 'Frameworks/**/*'
    s.pod_target_xcconfig = {
      'DEFINES_MODULE' => 'YES',
      'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
      'OTHER_LDFLAGS[sdk=iphoneos*]' => '-force_load ${PODS_TARGET_SRCROOT}/Frameworks/hzh_noise.xcframework/ios-arm64/libhzh_noise.a',
      'OTHER_LDFLAGS[sdk=iphonesimulator*]' => '-force_load ${PODS_TARGET_SRCROOT}/Frameworks/hzh_noise.xcframework/ios-arm64_x86_64-simulator/libhzh_noise.a',
    }
  else
    s.script_phase = {
      :name => 'Build Rust library',
      :script => 'sh "$PODS_TARGET_SRCROOT/../cargokit/build_pod.sh" ../rust hzh_noise',
      :execution_position => :before_compile,
      :input_files => ['${BUILT_PRODUCTS_DIR}/cargokit_phony'],
      :output_files => ["${BUILT_PRODUCTS_DIR}/libhzh_noise.a"],
    }
    s.pod_target_xcconfig = {
      'DEFINES_MODULE' => 'YES',
      'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
      'OTHER_LDFLAGS' => '-force_load ${BUILT_PRODUCTS_DIR}/libhzh_noise.a',
    }
  end
end
