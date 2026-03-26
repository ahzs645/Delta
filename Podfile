platform :ios, '14.0'

inhibit_all_warnings!

target 'Delta' do
    use_modular_headers!

    pod 'SQLite.swift', '~> 0.12.0'
    pod 'SDWebImage', '~> 3.8'
    pod 'SMCalloutView', '~> 2.1.0'

    pod 'Roxas', :path => 'External/Roxas'
    pod 'Harmony', :path => 'External/Harmony'
end

target 'DeltaPreviews' do
    use_modular_headers!

    pod 'Roxas', :path => 'External/Roxas'
end

post_install do |installer|
    installer.pods_project.targets.each do |target|
        target.build_configurations.each do |config|
            config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '14.0'
            config.build_settings['SWIFT_ENABLE_EXPLICIT_MODULES'] = 'NO'
        end
    end

    # SwiftyDropbox's Objective-C implementation must import its public header
    # through the generated module when modular headers are enabled.
    swiftydropbox_impl = File.join(installer.sandbox.root.to_s, 'SwiftyDropbox', 'Source', 'SwiftyDropbox', 'Shared', 'Handwritten', 'DBChunkInputStream.m')
    if File.exist?(swiftydropbox_impl)
        content = File.read(swiftydropbox_impl)
        updated = content.gsub('#import "DBChunkInputStream.h"', '#import <SwiftyDropbox/DBChunkInputStream.h>')
        File.write(swiftydropbox_impl, updated) if updated != content
    end

    # Fix module map paths so Xcode's dependency scanner can find them before
    # pod targets are built.  CocoaPods places module maps at
    # PODS_CONFIGURATION_BUILD_DIR (the build-products dir), but the scanner
    # runs before targets compile.  Rewrite -fmodule-map-file= flags to
    # reference the committed copies in Pods/Target Support Files/.
    fix_xcconfig = lambda do |xcconfig_path|
        next unless File.exist?(xcconfig_path)
        content = File.read(xcconfig_path)
        sandbox_root = installer.sandbox.root.to_s

        # Replace each build-dir modulemap ref with the source-dir copy.
        content.gsub!(/\$\{PODS_CONFIGURATION_BUILD_DIR\}\/([^\/]+)\/([^"]+\.modulemap)/) do
            pod_dir = $1
            map_file = $2
            source_dir = File.join(sandbox_root, 'Target Support Files', pod_dir)
            # Prefer the actual file on disk (handles naming mismatches like
            # SQLite.swift.modulemap vs SQLite.modulemap).
            actual = Dir.glob(File.join(source_dir, '*.modulemap')).first
            if actual
                "${PODS_ROOT}/Target Support Files/#{pod_dir}/#{File.basename(actual)}"
            else
                "${PODS_ROOT}/Target Support Files/#{pod_dir}/#{map_file}"
            end
        end

        # Add source-dir entries to SWIFT_INCLUDE_PATHS so the Swift compiler
        # can also find modulemaps before pods are built.
        if content[/^SWIFT_INCLUDE_PATHS\s*=/]
            build_dirs = content.scan(/"\$\{PODS_CONFIGURATION_BUILD_DIR\}\/([^"\/]+)"/).flatten.uniq
            source_entries = build_dirs.map { |d|
                "\"${PODS_ROOT}/Target Support Files/#{d}\""
            }
            unless source_entries.empty?
                content.sub!(
                    /^(SWIFT_INCLUDE_PATHS\s*=\s*.*)$/,
                    "\\1 #{source_entries.join(' ')}"
                )
            end
        end

        File.write(xcconfig_path, content)
    end

    installer.aggregate_targets.each do |aggregate_target|
        aggregate_target.xcconfigs.each do |config_name, _|
            fix_xcconfig.call(aggregate_target.xcconfig_path(config_name))
        end
    end

    installer.pod_targets.each do |pod_target|
        pod_target.build_settings.each do |config_name, _|
            fix_xcconfig.call(pod_target.xcconfig_path(config_name))
        end
    end
end
