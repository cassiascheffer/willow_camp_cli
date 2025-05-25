require "json"
require "uri"
require "net/http"
require "optparse"
require "pathname"
require "colorize"

module WillowCampCLI
  class CLI
    API_URL = "https://willow.camp/"
    attr_reader :token, :verbose

    def initialize(options)
      @token = options[:token]
      @directory = options[:directory]
      @dry_run = options[:dry_run]
      @verbose = options[:verbose]
      @slug = options[:slug]
    end

    # List all posts
    def list_posts
      puts "📋 Listing all posts from #{API_URL}...".blue

      response = api_request(:get, "/api/posts")
      if response
        posts = JSON.parse(response.body)["posts"]
        if posts.empty?
          puts "No posts found".yellow
        else
          puts "\nFound #{posts.size} post(s):".green
          posts.each do |post|
            puts "- [#{post["id"]}] #{post["slug"]}".cyan
          end
        end
      end
    end

    # Show a single post by slug
    def show_post
      return puts "Error: Slug is required".red unless @slug

      puts "🔍 Fetching post with slug: #{@slug}...".blue

      response = api_request(:get, "/api/posts/#{@slug}")
      if response
        post = JSON.parse(response.body)["post"]
        puts "\nPost details:".green
        puts "ID: #{post["id"]}".cyan
        puts "Slug: #{post["slug"]}".cyan
        puts "Title: #{post.dig("title")}".cyan
        puts "Published: #{post["published"] || false}".cyan
        puts "Published at: #{post["published_at"] || "Not published"}".cyan
        puts "Tags: #{(post["tag_list"] || []).join(", ")}".cyan

        if @verbose
          puts "\nContent:".cyan
          puts "-" * 50
          puts post["markdown"]
          puts "-" * 50
        end
      end
    end

    # Update a post by slug
    def update_post(content)
      return puts "Error: Slug and content are required".red unless @slug && content

      puts "🔄 Updating post with slug: #{@slug}...".blue

      if @dry_run
        puts "  DRY RUN: Would update post #{@slug}".yellow
        puts "  Content preview: #{content[0..100]}...".yellow if @verbose
        return
      end

      response = api_request(:patch, "/api/posts/#{@slug}", {post: {markdown: content}})
      if response
        post = JSON.parse(response.body)["post"]
        puts "✅ Successfully updated post: #{post["title"]} (#{post["slug"]})".green
      end
    end

    # Delete a post by slug
    def delete_post
      return puts "Error: Slug is required".red unless @slug

      puts "🗑️ Deleting post with slug: #{@slug}...".blue

      if @dry_run
        puts "  DRY RUN: Would delete post #{@slug}".yellow
        return
      end

      response = api_request(:delete, "/api/posts/#{@slug}")
      if response && response.code.to_i == 204
        puts "✅ Successfully deleted post: #{@slug}".green
      end
    end

    # Upload a single Markdown file
    def upload_file(file_path)
      puts "📤 Uploading #{file_path}...".blue
      content = File.read(file_path)

      if @dry_run
        puts "  DRY RUN: Would upload #{file_path}".yellow
        puts "  Content preview: #{content[0..100]}...".yellow if @verbose
        return
      end

      response = api_request(:post, "/api/posts", {post: {markdown: content}})
      if response
        post = JSON.parse(response.body)["post"]
        puts "✅ Successfully uploaded: #{file_path}".green
        puts "📌 Created post '#{post["title"]}' with slug: #{post["slug"]}".green
      end
    end

    # Upload all Markdown files from a directory
    def upload_all
      puts "🔍 Looking for Markdown files in #{@directory}...".blue

      files = find_markdown_files
      if files.empty?
        puts "❌ No Markdown files found in #{@directory}".red
        return
      end

      puts "📝 Found #{files.size} Markdown file(s)".blue

      files.each_with_index do |file, index|
        puts "\n[#{index + 1}/#{files.size}] Processing #{file}".cyan
        upload_file(file)
      end

      puts "\n✅ Operation complete!".green
    end

    # Download a post to a file
    def download_post(output_path)
      return puts "Error: Slug is required".red unless @slug

      puts "📥 Downloading post with slug: #{@slug}...".blue

      response = api_request(:get, "/api/posts/#{@slug}")
      if response
        post = JSON.parse(response.body)["post"]

        # Use provided output path or generate one based on slug
        output_path ||= "#{@slug}.md"

        File.write(output_path, post["markdown"])
        puts "✅ Successfully downloaded post to #{output_path}".green
      end
    end

    def self.run(args, testing = false)
      command = args.shift
      commands = %w[list show create update delete upload download help]

      unless commands.include?(command)
        puts "Unknown command: #{command}".red
        puts "Available commands: #{commands.join(", ")}"
        return false if testing
        exit(1)
      end

      # Parse command-line options
      options = {
        token: ENV["WILLOW_API_TOKEN"],
        directory: ".",
        file: nil,
        slug: nil,
        output: nil,
        dry_run: false,
        verbose: false
      }

      opt_parser = OptionParser.new do |opts|
        opts.banner = "Usage: willow-camp COMMAND [options]"
        opts.separator ""
        opts.separator "Commands:"
        opts.separator "  list                List all posts"
        opts.separator "  show                Show a single post by slug"
        opts.separator "  create              Create a new post from a Markdown file"
        opts.separator "  update              Update an existing post by slug"
        opts.separator "  delete              Delete a post by slug"
        opts.separator "  upload              Bulk upload posts from a directory"
        opts.separator "  download            Download a post to a Markdown file"
        opts.separator "  help                Show this help message"
        opts.separator ""
        opts.separator "Options:"



        opts.on("-t", "--token TOKEN", "API Bearer Token") do |token|
          options[:token] = token
        end

        opts.on("-d", "--directory DIRECTORY", "Directory containing Markdown files (for upload)") do |dir|
          options[:directory] = dir
        end

        opts.on("-f", "--file FILE", "Single Markdown file (for create/update)") do |file|
          options[:file] = file
        end

        opts.on("-s", "--slug SLUG", "Post slug (for show/update/delete/download)") do |slug|
          options[:slug] = slug
        end

        opts.on("-o", "--output FILE", "Output file (for download)") do |file|
          options[:output] = file
        end

        opts.on("--dry-run", "Show what would be done without making actual changes") do
          options[:dry_run] = true
        end

        opts.on("-v", "--verbose", "Show detailed output") do
          options[:verbose] = true
        end

        opts.on("-h", "--help", "Show this help message") do
          puts opts
          exit
        end
      end

      # Special case for help command
      if command == "help"
        puts opt_parser
        exit
      end

      # Parse the command-line arguments
      opt_parser.parse!(args)

      # Validate required options for each command
      case command
      when "list"
        # No specific validation needed
      when "show", "delete", "download"
        if !options[:slug]
          puts "Error: Slug is required for #{command} command (use --slug)".red
          exit 1
        end
      when "create"
        if !options[:file]
          puts "Error: File path is required for create command (use --file)".red
          exit 1
        end
      when "update"
        if !options[:slug] || !options[:file]
          puts "Error: Both slug and file are required for update command (use --slug and --file)".red
          exit 1
        end
      when "upload"
        # No specific validation needed beyond the common ones
      end

      # Common validation for token (except for dry runs)
      unless options[:token] || options[:dry_run]
        puts "Error: API token is required (unless using --dry-run)".red
        puts "Try 'willow-camp help' for more information"
        exit 1
      end

      # Create client and execute command
      begin
        client = new(options)

        case command
        when "list"
          client.list_posts
        when "show"
          client.show_post
        when "create"
          content = File.read(options[:file])
          client.upload_file(options[:file])
        when "update"
          content = File.read(options[:file])
          client.update_post(content)
        when "delete"
          client.delete_post
        when "upload"
          client.upload_all
        when "download"
          client.download_post(options[:output])
        end
      rescue => e
        puts "Error: #{e.message}".red
        exit 1
      end
    end

    private

    def find_markdown_files
      Dir.glob(File.join(@directory, "**", "*.md"))
    end

    def api_request(method, endpoint, data = nil)
      uri = URI("#{API_URL}#{endpoint}")

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"

      case method
      when :get
        request = Net::HTTP::Get.new(uri)
      when :post
        request = Net::HTTP::Post.new(uri)
      when :patch
        request = Net::HTTP::Patch.new(uri)
      when :delete
        request = Net::HTTP::Delete.new(uri)
      else
        puts "❌ Unsupported HTTP method: #{method}".red
        return nil
      end

      request["Content-Type"] = "application/json"
      request["Authorization"] = "Bearer #{@token}" if @token
      request.body = data.to_json if data

      if @verbose
        puts "🔗 API Endpoint: #{uri} (#{method.to_s.upcase})".blue
        puts "📄 Request body: #{request.body}" if request.body && @verbose
      end

      begin
        response = http.request(request)

        case response.code.to_i
        when 200..299
          response
        else
          puts "❌ API request failed: HTTP #{response.code}".red
          puts "Error: #{response.body}".red
          nil
        end
      rescue => e
        puts "❌ Error making API request: #{e.message}".red
        nil
      end
    end
  end
end
