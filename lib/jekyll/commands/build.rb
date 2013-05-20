require 'uglifier'
module Jekyll
  module Commands
    class Build < Command
      def self.process(options)
        site = Jekyll::Site.new(options)

        self.build(site, options)
        self.watch(site, options) if options['watch']
      end

      def self.build_all_locales(options)
        site = Jekyll::Site.new(options)
        locales = self.get_locales

        unless locales
          puts "You did not create .yml files in the _locales folder"
          puts "Please create files like this: de.yml"
          return
        end
        @export_path = "_production"
        return unless self.create_production_dir

        locales.each do |locale|
          site.config["locale"] = locale
          return if !self.minify(site, options)
          new_path = @export_path + "/" + locale
          FileUtils.cp_r "_site", "#{new_path}"
        end
        locales.each do |locale|
          new_path = @export_path + "/" + locale
          puts "Exported #{locale} to: #{new_path}"
        end
      end

      def self.create_production_dir
        begin
          # remove old production dir.
          FileUtils.rm_rf "./#{@export_path}"
          FileUtils.mkdir "./#{@export_path}"
        rescue
          nil
        end
      end

      # Check the available locales as an array.
      #
      # Returns an array of locales ["en", "de"]
      def self.get_locales
        # returns ["de.yml", "./_locales/en.yml"]
        begin
          locales = Dir.glob(File.join("./_locales/", "*"))
          locales.map{|locale| locale.split(".yml")[0].split("/")[-1] }
        rescue
          nil
        end
      end

      # Minify all the assets for the jekyll installation.
      # Make sure the _config.yml is properly set up
      # TODO this is still hacky.
      def self.minify(site, options)

        # 1. generate application once to have assets in proper location
        self.build(site, options)

        # 2. Create temp directory
        temp_dir_name = "_tmp"
        self.create_temp_directory temp_dir_name

        # 3. Extract assets into temp directory.
        self.extract_assets_temp_directory(temp_dir_name, generated_asset_paths(site))

        # 4. Minify extracted assets into one file.
        output_name = "application-#{Time.now.to_i}"

        # 4.1 CSS
        css_filenames = self.priority_asset_names(site.config["assets"]["css"], "css", "")
        css_filenames_temp_prefix = self.prefix_with_directory(temp_dir_name, css_filenames)
        minified_css = self.minify_css(temp_dir_name, css_filenames_temp_prefix, output_name)

        # 4.2 JS
        js_filenames = self.priority_asset_names(site.config["assets"]["js"], "js", "")
        js_filenames_temp_prefix = self.prefix_with_directory(temp_dir_name, js_filenames)
        minified_js = self.minify_js(temp_dir_name, js_filenames_temp_prefix, output_name)

        raise "Could not minify JS or CSS" if !minified_css || !minified_js

        # 5. Generate application again, modify asset pipeline
        old_config = site.config["assets"]
        # deep copy to new object
        new_config = Marshal.load(Marshal.dump(site.config["assets"]))
        new_config = self.minified_assets_config(output_name, new_config)

        site.config["assets"] = new_config
        self.build(site, options)
        site.config["assets"] = old_config

        # 6 Delete non minified assets
        self.delete_built_assets(site)

        # 7. Copy minified assets into app.
        target_dir = "#{site.config["source"]}/_site/assets"
        # 7.1 CSS
        css_copied = self.copy_file_target("#{temp_dir_name}/#{output_name}.css", "#{target_dir}/css/")
        # 7.2 JS
        js_copied = self.copy_file_target("#{temp_dir_name}/#{output_name}.js", "#{target_dir}/js/")

        raise "Could not copy minified assets" if !css_copied || !js_copied

        # 8. delete temp directory
        self.delete_temp_directory(temp_dir_name)

        true
      end

      def self.generated_asset_paths(site)
        begin
          assets = site.config["assets"]
        rescue
          raise "Please make sure to create the assets directive in your config"
        end
        return if !assets
        directory = "#{site.config["source"]}/_site"

        self.built_js_files_paths(directory, assets) + self.built_css_files_paths(directory, assets)
      end

      def self.built_css_files_paths(base_dir, asset_files)
        asset_file_names = self.priority_asset_names(asset_files["css"], "css")
        self.prefix_with_directory("#{base_dir}/assets/css", asset_file_names)
      end

      def self.built_js_files_paths(base_dir, asset_files)
        asset_file_names = self.priority_asset_names(asset_files["js"], "js")
        self.prefix_with_directory("#{base_dir}/assets/js", asset_file_names)
      end

      def self.prefix_with_directory(directory, assets)
        assets.map{|asset| directory + "/" + asset }
      end

      # Expects the asset hash in this format:
      # css: {"lib" => [], "custom" => []}
      # js: {"lib" => [], "custom" => []}
      # type: css or js to add as filename at the end
      # lib_path an optional lib path
      def self.priority_asset_names(asset_hash, type, lib_path = "lib/")
        libs = asset_hash["lib"].map{|asset| lib_path + asset + ".#{type}"}
        custom = asset_hash["custom"].map{|asset| asset + ".#{type}"}
        libs + custom
      end

      def self.extract_assets_temp_directory(temp_dir_name, asset_locations)
        begin
          asset_locations.each do |loc|
            FileUtils.cp_r loc, "./#{temp_dir_name}/"
          end
          asset_locations
        rescue
          nil
        end
      end

      def self.create_temp_directory(tmp_name)
        begin
          # remove old production dir.
          FileUtils.rm_rf "./#{tmp_name}"
          FileUtils.mkdir "./#{tmp_name}"
        rescue
          nil
        end
      end

      def self.delete_temp_directory(tmp_name)
        begin
          # remove old production dir.
          FileUtils.rm_rf "./#{tmp_name}"
        rescue
          nil
        end
      end


      def self.minify_css(temp_dir_name, files, output_name)
        self.minify_assets(self.blank_filename_string(files), "#{temp_dir_name}/#{output_name}.css")
      end

      def self.minify_js(temp_dir_name, files, output_name)
        output_file = "#{temp_dir_name}/#{output_name}.js"
        begin
          merge_files = ""
          files.each do |file_path|
            merge_files += File.read(file_path) + "\n"
          end
          minified = Uglifier.new.compile(merge_files)
          File.open(output_file, 'w') {|f| f.write(minified) }
          output_file
        rescue
          false
        end
      end

      # Minify assets
      # Expect path to assets from current dir
      # File name where to store the compiled assets
      def self.minify_assets(files, output_name)
        minify_command = "juicer merge #{files} -o #{output_name}"
        begin
          result = system(minify_command)
          return if !result
          output_name
        rescue
          raise "Could not minify files."
        end
      end

      def self.blank_filename_string(files)
        file_names_string = ""
        files.each_with_index do |f, index|
          if index == 0
            file_names_string += "#{f}"
          else
            file_names_string += " #{f}"
          end
        end
        file_names_string
      end

      def self.copy_minified_css(css, filename)
      end

      def self.copy_minified_js(js, filename)
      end

      def remove_old_stylesheets
        #
        nil
      end

      def self.delete_built_assets(site)
        begin
          self.generated_asset_paths(site).each do |file|
            FileUtils.rm file
          end
          true
        rescue
          nil
        end
      end

      # Modifies the assets hash to include the minified files.
      def self.minified_assets_config(output_name, assets)
        # site assets hash looks like this:
        # {
        #   "css"=> {
        #     "lib"=>["lib1", "lib2"],
        #     "custom"=>["styles"]
        #   },
        #   "js"=>{
        #     "lib"=>["lib1", "lib2"],
        #     "custom"=>["js"]}
        # }
        assets["css"].delete("lib")
        assets["js"].delete("lib")
        assets["css"]["custom"] = ["#{output_name}"]
        assets["js"]["custom"] = ["#{output_name}"]
        assets
      end

      def self.copy_file_target(file, target)
        begin
          FileUtils.cp_r file, target
          true
        rescue
          nil
        end
      end


      # Private: Build the site from source into destination.
      #
      # site - A Jekyll::Site instance
      # options - A Hash of options passed to the command
      #
      # Returns nothing.
      def self.build(site, options)
        source = options['source']
        destination = options['destination']
        Jekyll::Stevenson.info "Source:", source
        Jekyll::Stevenson.info "Destination:", destination
        print Jekyll::Stevenson.formatted_topic "Generating..."
        self.process_site(site)
        puts "done."
      end

      # Private: Watch for file changes and rebuild the site.
      #
      # site - A Jekyll::Site instance
      # options - A Hash of options passed to the command
      #
      # Returns nothing.
      def self.watch(site, options)
        require 'directory_watcher'

        source = options['source']
        destination = options['destination']

        Jekyll::Stevenson.info "Auto-regeneration:", "enabled"

        dw = DirectoryWatcher.new(source, :glob => self.globs(source, destination), :pre_load => true)
        dw.interval = 1

        dw.add_observer do |*args|
          t = Time.now.strftime("%Y-%m-%d %H:%M:%S")
          print Jekyll::Stevenson.formatted_topic("Regenerating:") + "#{args.size} files at #{t} "
          self.process_site(site)
          puts  "...done."
        end

        dw.start

        unless options['serving']
          trap("INT") do
            puts "     Halting auto-regeneration."
            exit 0
          end

          loop { sleep 1000 }
        end
      end
    end
  end
end
