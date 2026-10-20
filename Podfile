# Uncomment the next line to define a global platform for your project
platform :osx, "10.13"

target "GoldenPassport" do
  # Comment the next line if you're not using Swift and don't want to use dynamic frameworks
  use_frameworks!

  # Pods for GoldenPassport
  pod "Swifter", "~> 1.5.0"
end

# Swifter 的 podspec 声明最低 macOS 10.10，新版 Xcode 编译低于 10.13 的目标会因缺少 libarclite 失败，
# 这里统一抬到 10.13（与主工程一致）
post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      if config.build_settings['MACOSX_DEPLOYMENT_TARGET'].to_f < 10.13
        config.build_settings['MACOSX_DEPLOYMENT_TARGET'] = '10.13'
      end
    end
  end
end
