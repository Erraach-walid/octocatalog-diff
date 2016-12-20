# frozen_string_literal: true

require 'json'
require 'stringio'

require_relative 'catalog/computed'
require_relative 'catalog/json'
require_relative 'catalog/noop'
require_relative 'catalog/puppetdb'
require_relative 'catalog/puppetmaster'
require_relative 'catalog-util/fileresources'

module OctocatalogDiff
  # This class represents a catalog. Generation of the catalog is handled via one of the
  # supported backends listed above as 'require_relative'. Usually, the 'computed' backend
  # will build the catalog from the Puppet command.
  class Catalog
    # Readable
    attr_reader :built, :catalog, :catalog_json

    # Error classes that we can throw
    class PuppetVersionError < RuntimeError; end
    class CatalogError < RuntimeError; end

    # Constructor
    # @param :backend [Symbol] If set, this will force a backend
    # @param :json [String] JSON catalog content (will avoid running Puppet to compile catalog)
    # @param :puppetdb [Object] If set, pull the catalog from PuppetDB rather than building
    # @param :node [String] Name of node whose catalog is being built
    # @param :fact_file [String] OPTIONAL: Path to fact file (if not provided, look up in PuppetDB)
    # @param :hiera_config [String] OPTIONAL: Path to hiera config file (munge temp. copy if not provided)
    # @param :basedir [String] OPTIONAL: Base directory for catalog (default base directory of this checkout)
    # @param :pass_env_vars [Array<String>] OPTIONAL: Additional environment vars to pass
    # @param :convert_file_resources [Boolean] OPTIONAL: Convert file resource source to content
    # @param :storeconfigs [Boolean] OPTIONAL: Pass the '-s' flag, for puppetdb (storeconfigs) integration
    def initialize(options = {})
      @options = options

      # Call appropriate backend for catalog generation
      @catalog_obj = backend(options)

      # The catalog is not built yet, except if the backend has no build method
      @built = false
      build unless @catalog_obj.respond_to?(:build)

      # The compilation directory can be overridden, e.g. when testing
      @override_compilation_dir = nil
    end

    # Build catalog - this method needs to be called to build the catalog. It is separate due to
    # the serialization of the logger object -- the parallel gem cannot serialize/deserialize a logger
    # object so it cannot be part of any object that is passed around.
    # @param logger [Logger] Logger object, initialized to a default throwaway value
    def build(logger = Logger.new(StringIO.new))
      # Only build once
      return if @built
      @built = true

      # Call catalog's build method.
      if @catalog_obj.respond_to?(:build)
        logger.debug "Calling build for object #{@catalog_obj.class}"
        @catalog_obj.build(logger)
      end

      # These methods must exist in all backends
      @catalog = @catalog_obj.catalog
      @catalog_json = @catalog_obj.catalog_json
      @error_message = @catalog_obj.error_message

      # The resource hash is computed the first time it's needed. For now initialize it as nil.
      @resource_hash = nil

      # Perform post-generation processing of the catalog
      return unless valid?
      unless @catalog_obj.respond_to?(:convert_file_resources) && @catalog_obj.convert_file_resources == false
        OctocatalogDiff::CatalogUtil::FileResources.convert_file_resources(self) if @options.fetch(:compare_file_text, false)
      end
    end

    # For logging we may wish to know the backend being used
    # @return [String] Class of backend used
    def builder
      @catalog_obj.class.to_s
    end

    # Set the catalog JSON
    # @param str [String] Catalog JSON
    def catalog_json=(str)
      @catalog_json = str
      @resource_hash = nil
    end

    # This retrieves the compilation directory from the catalog, or otherwise the passed-in directory.
    # @return [String] Compilation directory
    def compilation_dir
      return @override_compilation_dir if @override_compilation_dir
      @catalog_obj.respond_to?(:compilation_dir) ? @catalog_obj.compilation_dir : @options[:basedir]
    end

    # The compilation directory can be overridden, e.g. during testing.
    # @param dir [String] Compilation directory
    def compilation_dir=(dir)
      @override_compilation_dir = dir
    end

    # Determine whether the underlying catalog object supports :compare_file_text
    # @return [Boolean] Whether underlying catalog object supports :compare_file_text
    def convert_file_resources
      return true unless @catalog_obj.respond_to?(:convert_file_resources)
      @catalog_obj.convert_file_resources
    end

    # Retrieve the error message.
    # @return [String] Error message (maximum 20,000 characters) - nil if no error.
    def error_message
      return nil if @error_message.nil? || !@error_message.is_a?(String)
      @error_message[0, 20_000]
    end

    # Allow setting the error message. If the error message is set to a string, the catalog
    # and catalog JSON are set to nil.
    # @param error [String] Error message
    def error_message=(error)
      raise ArgumentError, 'Error message must be a string' unless error.is_a?(String)
      @error_message = error
      @catalog = nil
      @catalog_json = nil
      @resource_hash = nil
    end

    # This retrieves the version of Puppet used to compile a catalog. If the underlying catalog was not
    # compiled by running Puppet (e.g., it was read in from JSON or puppetdb), then this returns the
    # puppet version optionally passed in to the constructor. This can also be nil.
    # @return [String] Puppet version
    def puppet_version
      @catalog_obj.respond_to?(:puppet_version) ? @catalog_obj.puppet_version : @options[:puppet_version]
    end

    # This allows retrieving a resource by type and title. This is intended for use when a O(1) lookup is required.
    # @param :type [String] Type of resource
    # @param :title [String] Title of resource
    # @return [Hash] Resource item
    def resource(opts = {})
      raise ArgumentError, ':type and :title are required' unless opts[:type] && opts[:title]
      build_resource_hash if @resource_hash.nil?
      return nil unless @resource_hash[opts[:type]].is_a?(Hash)
      @resource_hash[opts[:type]][opts[:title]]
    end

    # This is a compatibility layer for the resources, which are in a different place in Puppet 3.x and Puppet 4.x
    # @return [Array] Resource array
    def resources
      raise CatalogError, 'Catalog does not appear to have been built' if !valid? && error_message.nil?
      raise CatalogError, error_message unless valid?
      return @catalog['data']['resources'] if @catalog['data'].is_a?(Hash) && @catalog['data']['resources'].is_a?(Array)
      return @catalog['resources'] if @catalog['resources'].is_a?(Array)
      # This is a bug condition
      # :nocov:
      raise "BUG: catalog has no data::resources or ::resources array. Please report this. #{@catalog.inspect}"
      # :nocov
    end

    # This retrieves the number of retries necessary to compile the catalog. If the underlying catalog
    # generation backend does not support retries, nil is returned.
    # @return [Integer] Retry count
    def retries
      @retries = @catalog_obj.respond_to?(:retries) ? @catalog_obj.retries : nil
    end

    # Determine if the catalog build was successful.
    # @return [Boolean] Whether the catalog is valid
    def valid?
      !@catalog.nil?
    end

    private

    # Private method: Choose backend based on passed-in options
    # @param options [Hash] Options passed into constructor
    # @return [Object] OctocatalogDiff::Catalog::<whatever> object
    def backend(options)
      # Hard-coded backend
      if options[:backend]
        return OctocatalogDiff::Catalog::JSON.new(options) if options[:backend] == :json
        return OctocatalogDiff::Catalog::PuppetDB.new(options) if options[:backend] == :puppetdb
        return OctocatalogDiff::Catalog::PuppetMaster.new(options) if options[:backend] == :puppetmaster
        return OctocatalogDiff::Catalog::Computed.new(options) if options[:backend] == :computed
        return OctocatalogDiff::Catalog::Noop.new(options) if options[:backend] == :noop
        raise ArgumentError, "Unknown backend :#{options[:backend]}"
      end

      # Determine backend based on arguments
      return OctocatalogDiff::Catalog::JSON.new(options) if options[:json]
      return OctocatalogDiff::Catalog::PuppetDB.new(options) if options[:puppetdb]
      return OctocatalogDiff::Catalog::PuppetMaster.new(options) if options[:puppet_master]

      # Default is to build catalog ourselves
      OctocatalogDiff::Catalog::Computed.new(options)
    end

    # Private method: Build the resource hash to be used used for O(1) lookups by type and title.
    # This method is called the first time the resource hash is accessed.
    def build_resource_hash
      @resource_hash = {}
      resources.each do |resource|
        @resource_hash[resource['type']] ||= {}
        @resource_hash[resource['type']][resource['title']] = resource
      end
    end
  end
end
