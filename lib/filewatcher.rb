# frozen_string_literal: true

# Simple file watcher. Detect changes in files and directories.
#
# Issues: Currently doesn't monitor changes in directorynames
class Filewatcher
  attr_writer :interval

  def update_spinner(label)
    return unless @show_spinner
    @spinner ||= %w[\\ | / -]
    print "#{' ' * 30}\r#{label}  #{@spinner.rotate!.first}\r"
  end

  def initialize(unexpanded_filenames, options = {})
    @unexpanded_filenames = unexpanded_filenames
    @unexpanded_excluded_filenames = options[:exclude]
    @keep_watching = false
    @pausing = false
    @immediate = options[:immediate]
    @show_spinner = options[:spinner]
    @interval = options.fetch(:interval, 0.5)
  end

  def watch(&on_update)
    trap('SIGINT') { return }
    @stored_update = on_update
    @keep_watching = true
    yield({}) if @immediate
    while @keep_watching
      @end_snapshot = mtime_snapshot if @pausing
      while @keep_watching && @pausing
        update_spinner('Pausing')
        sleep @interval
      end
      while @keep_watching && !filesystem_updated? && !@pausing
        update_spinner('Watching')
        sleep @interval
      end
      # test and clear @changes to prevent yielding the last
      # changes twice if @keep_watching has just been set to false
      thread = Thread.new do
        yield @changes if @changes.any?
        @changes.clear
      end
      thread.join
    end
    @end_snapshot = mtime_snapshot
    finalize(&on_update)
  end

  def pause
    @pausing = true
    update_spinner('Initiating pause')
    # Ensure we wait long enough to enter pause loop in #watch
    sleep @interval
  end

  def resume
    if !@keep_watching || !@pausing
      raise "Can't resume unless #watch and #pause were first called"
    end
    @last_snapshot = mtime_snapshot # resume with fresh snapshot
    @pausing = false
    update_spinner('Resuming')
    sleep @interval # Wait long enough to exit pause loop in #watch
  end

  # Ends the watch, allowing any remaining changes to be finalized.
  # Used mainly in multi-threaded situations.
  def stop
    @keep_watching = false
    update_spinner('Stopping')
    nil
  end

  # Calls the update block repeatedly until all changes in the
  # current snapshot are dealt with
  def finalize(&on_update)
    on_update = @stored_update unless block_given?
    snapshot = @end_snapshot ? @end_snapshot : mtime_snapshot
    while filesystem_updated?(snapshot)
      update_spinner('Finalizing')
      on_update.call(@changes)
    end
    @end_snapshot = nil
  end

  def last_found_filenames
    last_snapshot.keys
  end

  private

  def last_snapshot
    @last_snapshot ||= mtime_snapshot
  end

  # Takes a snapshot of the current status of watched files.
  # (Allows avoidance of potential race condition during #finalize)
  def mtime_snapshot
    snapshot = {}
    filenames = expand_directories(@unexpanded_filenames)

    # Remove files in the exclude filenames list
    filenames -= expand_directories(@unexpanded_excluded_filenames)

    filenames.each do |filename|
      mtime = File.exist?(filename) ? File.mtime(filename) : Time.new(0)
      snapshot[filename] = mtime
    end
    snapshot
  end

  def filesystem_updated?(snapshot = mtime_snapshot)
    @changes = {}

    (snapshot.to_a - last_snapshot.to_a).each do |file, _mtime|
      @changes[file] = last_snapshot[file] ? :updated : :created
    end

    (last_snapshot.to_a - snapshot.to_a).each do |file, _mtime|
      @changes[file] = :deleted
    end

    @last_snapshot = snapshot
    @changes.any?
  end

  def expand_directories(patterns)
    patterns = Array(patterns) unless patterns.is_a? Array
    expanded_patterns = patterns.map do |pattern|
      pattern = File.expand_path(pattern)
      Dir[
        File.directory?(pattern) ? File.join(pattern, '**', '*') : pattern
      ]
    end
    expanded_patterns.flatten!
    expanded_patterns.uniq!
    expanded_patterns
  end
end

# Require at end of file to not overwrite `Filewatcher` class
require_relative 'filewatcher/version'
