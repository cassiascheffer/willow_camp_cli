require "test_helper"
require "mocha/minitest" # Ensure Mocha integration with Minitest
require "willow_camp_cli"
require "timecop"
require "fileutils"
require "json" # For parsing mock response bodies if needed by CLI methods directly

module WillowCampCLI
  class SyncTest < Minitest::Test
    def setup
      @test_dir_base = File.expand_path(File.join(__dir__, "..", "tmp", "test_sync_dir"))
      @test_dir = "#{@test_dir_base}_#{SecureRandom.hex(4)}"
      FileUtils.mkdir_p(@test_dir)

      now = Time.now.utc
      @current_time = Time.utc(now.year, now.month, now.day, now.hour, now.min, now.sec) # Truncate to seconds

      @options = {
        token: "test_token",
        directory: @test_dir,
        dry_run: false,
        verbose: false,
        slug: nil
      }
      @cli = CLI.new(@options)

      # @mock_mtimes and @mock_contents are no longer used with global stubs.
      # Stubs for File.mtime and File.read will be set per test via mock_local_files.
      @mock_writes = {} # To track File.write calls: path -> content

      # Global stub for File.write remains as it's simpler and captures all writes.
      File.stubs(:write).with do |path, content|
        @mock_writes[path.to_s] = content
        true # Simulate successful write
      end.returns(true) # Return value for File.write is length of string or similar

      # Default empty remote posts
      stub_remote_posts([])
    end

    def teardown
      FileUtils.rm_rf(@test_dir_base) if Dir.exist?(@test_dir_base) # Clean up parent of unique test dirs
      Timecop.return
      # Mocha typically integrates with Minitest to handle stub teardown automatically.
      # Explicitly calling File.unstub might not be necessary or correctly applied here.
      # If issues persist, ensure `mocha/minitest` is required in test_helper.
    end

    # Helper to create a mock Net::HTTPResponse
    def mock_api_response(code, body_hash)
      response = Net::HTTPResponse.new("1.1", code.to_s, "Mock Message")
      response.instance_variable_set(:@body, body_hash.to_json)
      response.instance_variable_set(:@read, true)
      def response.[](key); {"content-type" => "application/json"}[key.downcase]; end
      response
    end

    # Helper to stub the initial remote post listing
    def stub_remote_posts(posts_array)
      # posts_array should be an array of post hashes, e.g., [{ "slug": "foo", "updated_at": "2023-01-01T12:00:00Z" }]
      @cli.stubs(:api_request).with(:get, "/api/posts?per_page=1000").returns(mock_api_response(200, { "posts" => posts_array }))
    end

    # Helper to simulate local files for find_markdown_files
    def mock_local_files(filenames_with_mtime_and_content)
      # { "slug1.md" => { mtime: Time.now, content: "..." } }
      found_files = []
      filenames_with_mtime_and_content.each do |filename, data|
        raise "data[:mtime] is nil for filename #{filename} in mock_local_files" if data[:mtime].nil?
        raise "data[:content] is nil for filename #{filename} in mock_local_files" if data[:content].nil?
        full_path = File.join(@test_dir, filename)
        found_files << full_path
        # Set specific stubs for File.mtime and File.read for this path
        File.stubs(:mtime).with(full_path).returns(data[:mtime])
        File.stubs(:read).with(full_path).returns(data[:content])
      end
      @cli.stubs(:find_markdown_files).returns(found_files)
    end

    # --- Test Cases ---

    # 1. New local file: A new Markdown file in the local directory should be uploaded as a new post.
    def test_01_new_local_file_uploads
      Timecop.freeze(@current_time)
      local_file_name = "new-post.md"
      local_file_path = File.join(@test_dir, local_file_name)
      local_content = "New content for new-post"

      mock_local_files({ local_file_name => { mtime: @current_time, content: local_content }})
      stub_remote_posts([]) # No remote posts initially

      # Expect upload_file to be called
      @cli.expects(:upload_file).with(local_file_path).once
      
      @cli.sync_directory
    end

    # 2. Updated local file: An existing local Markdown file that is newer than the corresponding remote post should update the remote post.
    def test_02_updated_local_file_updates_remote
      Timecop.freeze(@current_time)
      # @mock_mtimes and @mock_contents no longer reset here, handled by mock_local_files and per-test stubbing
      slug = "existing-post"
      local_file_name = "#{slug}.md"
      local_file_path = File.join(@test_dir, local_file_name)
      local_content = "Updated local content"
      
      remote_updated_at = @current_time - 3600 # Remote is 1 hour old
      local_mtime = @current_time # Local is newer

      mock_local_files({ local_file_name => { mtime: local_mtime, content: local_content }})
      stub_remote_posts([{ "slug" => slug, "updated_at" => remote_updated_at.iso8601, "id" => "123" }])

      # Expect update_post to be called
      # @cli.expects(:update_post).with(local_content).once # update_post uses @slug
      # Instead, we check the API call directly or the effect of update_post
      
      # Mock the PATCH request for update
      @cli.expects(:api_request).with(:patch, "/api/posts/#{slug}", { post: { markdown: local_content } }).once.returns(mock_api_response(200, {"post" => {"slug" => slug, "title" => "Updated Post"}}))

      @cli.sync_directory
      # The @slug instance variable is reset to nil at the end of sync_directory.
      # The more important check is that the correct API request was made with the slug, which is done above.
    end

    # 3. Unchanged local file: A local file that is older or has the same modification time as the remote post should not be uploaded.
    def test_03_unchanged_local_file_is_skipped
      Timecop.freeze(@current_time)
      # @mock_mtimes and @mock_contents no longer reset here
      slug = "static-post"
      local_file_name = "#{slug}.md"
      local_content = "Static content"

      # Scenario 1: Local is older
      remote_updated_at = @current_time
      local_mtime_older = @current_time - 3600
      mock_local_files({ local_file_name => { mtime: local_mtime_older, content: local_content }})
      stub_remote_posts([{ "slug" => slug, "updated_at" => remote_updated_at.iso8601, "id" => "123" }])

      @cli.expects(:update_post).never
      @cli.expects(:upload_file).never
      # Check that no PATCH or POST request is made for this slug
      @cli.expects(:api_request).with(:patch, anything, anything).never
      @cli.expects(:api_request).with(:post, anything, anything).never
      
      @cli.sync_directory

      # Scenario 2: Local is same time
      Timecop.freeze # unfreeze briefly to reset mtime
      local_mtime_same = @current_time
      Timecop.freeze(@current_time) # re-freeze
      mock_local_files({ local_file_name => { mtime: local_mtime_same, content: local_content }})
      # Remote posts stubbing remains the same

      @cli.expects(:update_post).never
      @cli.expects(:upload_file).never
      @cli.expects(:api_request).with(:patch, anything, anything).never
      @cli.expects(:api_request).with(:post, anything, anything).never

      @cli.sync_directory
    end

    # 4. New remote post: A remote post that does not have a corresponding local file should be downloaded.
    def test_04_new_remote_post_is_downloaded
      Timecop.freeze(@current_time)
      remote_slug = "new-remote-post"
      remote_content_md = "Content from new remote post"
      
      mock_local_files({}) # No local files
      stub_remote_posts([{ "slug" => remote_slug, "updated_at" => @current_time.iso8601, "id" => "456", "markdown" => remote_content_md }])

      # Expect download_post to be called (indirectly, by checking for the API GET and File.write)
      # download_post makes a GET request for the specific post
      @cli.expects(:api_request).with(:get, "/api/posts/#{remote_slug}").once.returns(mock_api_response(200, {"post" => {"slug" => remote_slug, "markdown" => remote_content_md, "id" => "456"}}))
      
      @cli.sync_directory # This will trigger File.write via download_post

      expected_local_path = File.join(@test_dir, "#{remote_slug}.md")
      assert_equal remote_content_md, @mock_writes[expected_local_path]
    end

    # 5. Dry run: Test that --dry-run prevents actual API calls and file system changes.
    def test_05_dry_run_new_local_file
      Timecop.freeze(@current_time)
      @cli.instance_variable_set(:@dry_run, true) # Enable dry run on the existing @cli instance

      local_file_name = "dry-run-new.md"
      # local_file_path = File.join(@test_dir, local_file_name) # Unused variable
      local_content = "Dry run new content"

      mock_local_files({ local_file_name => { mtime: @current_time, content: local_content }})
      stub_remote_posts([])

      # Ensure no actual upload method (which makes API call) is hit
      @cli.expects(:api_request).with(:post, "/api/posts", anything).never
      
      output, _err = capture_io do
        @cli.sync_directory
      end

      assert_match(/DRY RUN: Would create remote post '#{File.basename(local_file_name, ".md")}'/, output)
    end

    def test_05_dry_run_updated_local_file
      Timecop.freeze(@current_time)
      # @mock_mtimes and @mock_contents no longer reset here
      @cli.instance_variable_set(:@dry_run, true)
      slug = "dry-run-existing"
      local_file_name = "#{slug}.md"
      local_content = "Dry run updated content"
      
      mock_local_files({ local_file_name => { mtime: @current_time, content: local_content }})
      stub_remote_posts([{ "slug" => slug, "updated_at" => (@current_time - 3600).iso8601, "id" => "789" }])

      @cli.expects(:api_request).with(:patch, "/api/posts/#{slug}", anything).never
      
      output, _err = capture_io do
        @cli.sync_directory
      end
      assert_match(/DRY RUN: Would update remote post '#{slug}'/, output)
    end

    def test_05_dry_run_new_remote_post
      Timecop.freeze(@current_time)
      @cli.instance_variable_set(:@dry_run, true)
      remote_slug = "dry-run-new-remote"
      
      mock_local_files({})
      stub_remote_posts([{ "slug" => remote_slug, "updated_at" => @current_time.iso8601, "id" => "101" }])

      # download_post makes a GET, but File.write should not happen
      # The initial GET for all posts is fine. The GET for the specific post to download is also fine.
      # We must ensure File.write is not called.
      # @mock_writes will be checked.
      
      output, _err = capture_io do
        @cli.sync_directory
      end

      expected_local_path = File.join(@test_dir, "#{remote_slug}.md")
      assert_nil @mock_writes[expected_local_path] # File.write was not called
      assert_match(/DRY RUN: Would download remote post '#{remote_slug}'/, output)
    end

    # 6. Empty local directory and no remote posts: Syncing an empty directory with no remote posts should result in no actions.
    def test_06_empty_local_empty_remote
      Timecop.freeze(@current_time)
      mock_local_files({})
      stub_remote_posts([])

      # No API calls beyond the initial GET /api/posts
      @cli.expects(:api_request).with(:post, anything, anything).never
      @cli.expects(:api_request).with(:patch, anything, anything).never
      @cli.expects(:api_request).with(:get, %r{/api/posts/[^?]+$}).never # No specific post GETs
      
      # No file writes
      # @mock_writes will be checked implicitly by not having anything written.

      _output, _err = capture_io do
        @cli.sync_directory
      end
      # Ensure no "Creating", "Updating", "Downloading" messages. Verbose might say "Skipping".
      # For non-verbose, output should be minimal.
      # We can check that @mock_writes is empty.
      assert @mock_writes.empty?, "File.write should not have been called."
    end

    # 7. Local directory with files, but no remote posts: All local files should be uploaded.
    def test_07_local_files_no_remote
      Timecop.freeze(@current_time)
      
      files_to_upload = {
        "post1.md" => { mtime: @current_time, content: "Content for post1" },
        "post2.md" => { mtime: @current_time, content: "Content for post2" }
      }
      mock_local_files(files_to_upload)
      stub_remote_posts([])

      # Expect upload_file to be called for each
      @cli.expects(:upload_file).with(File.join(@test_dir, "post1.md")).once
      @cli.expects(:upload_file).with(File.join(@test_dir, "post2.md")).once
      
      @cli.sync_directory
    end

    # 8. No local files, but remote posts exist: All remote posts should be downloaded.
    def test_08_no_local_files_remote_posts_exist
      Timecop.freeze(@current_time)
      
      remote_posts_data = [
        { "slug" => "remote1", "updated_at" => @current_time.iso8601, "id" => "r1", "markdown" => "Content for remote1" },
        { "slug" => "remote2", "updated_at" => @current_time.iso8601, "id" => "r2", "markdown" => "Content for remote2" }
      ]
      mock_local_files({})
      stub_remote_posts(remote_posts_data)

      # Expect download_post to be called for each (indirectly by checking API GET and File.write)
      @cli.expects(:api_request).with(:get, "/api/posts/remote1").once.returns(mock_api_response(200, {"post" => remote_posts_data[0]}))
      @cli.expects(:api_request).with(:get, "/api/posts/remote2").once.returns(mock_api_response(200, {"post" => remote_posts_data[1]}))
      
      @cli.sync_directory

      assert_equal "Content for remote1", @mock_writes[File.join(@test_dir, "remote1.md")]
      assert_equal "Content for remote2", @mock_writes[File.join(@test_dir, "remote2.md")]
    end
  end
end
