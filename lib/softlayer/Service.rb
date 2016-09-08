#--
# Copyright (c) 2014 SoftLayer Technologies, Inc. All rights reserved.
#
# For licensing information see the LICENSE.md file in the project root.
#++

require 'xmlrpc/client'

# utility routine for swapping constants without warnings.
def with_warnings(flag)
  old_verbose, $VERBOSE = $VERBOSE, flag
  yield
ensure
  $VERBOSE = old_verbose
end

with_warnings(nil) {
  # enable parsing of "nil" values in structures returned from the API
  XMLRPC::Config.const_set('ENABLE_NIL_PARSER', true)
  # enable serialization of "nil" values in structures sent to the API
  XMLRPC::Config.const_set('ENABLE_NIL_CREATE', true)
}

# The XML-RPC spec calls for the "faultCode" in faults to be an integer
# but the SoftLayer XML-RPC API can return strings as the "faultCode"
#
# We monkey patch the module method XMLRPC::FaultException::Convert::fault
# so that it does pretty much what the default does without checking
# to ensure that the faultCode is an integer
module XMLRPC::Convert
  def self.fault(hash)
    if hash.kind_of? Hash and hash.size == 2 and
      hash.has_key? "faultCode" and hash.has_key? "faultString" and
      (hash['faultCode'].kind_of?(Integer) || hash['faultCode'].kind_of?(String)) and hash['faultString'].kind_of? String

      XMLRPC::FaultException.new(hash['faultCode'], hash['faultString'])
    else
      super
    end
  end
end

module SoftLayer
  # = SoftLayer API Service
  #
  # Instances of this class are the runtime representation of
  # services in the SoftLayer API. They handle communication with
  # the SoftLayer servers.
  #
  # You typically should not need to create services directly.
  # instead, you should be creating a client and then using it to
  # obtain individual services. For example:
  #
  #     client = SoftLayer::Client.new(:username => "Joe", :api_key=>"feeddeadbeefbadfood...")
  #     account_service = client.service_named("Account") # returns the SoftLayer_Account service
  #     account_service = client[:Account] # Exactly the same as above
  #
  # For backward compatibility, a service can be constructed by passing
  # client initialization options, however if you do so you will need to
  # prepend the "SoftLayer_" on the front of the service name. For Example:
  #
  #     account_service = SoftLayer::Service("SoftLayer_Account",
  #     :username=>"<your user name here>"
  #     :api_key=>"<your api key here>")
  #
  # A service communicates with the SoftLayer API through the the XML-RPC
  # interface using Ruby's built in classes
  #
  # Once you have a service, you can invoke methods in the service like this:
  #
  #     account_service.getOpenTickets
  #     => {... lots of information here representing the list of open tickets ...}
  #
  class Service
    # The name of the service that this object calls. Cannot be empty or nil.
    attr_reader :service_name
    attr_reader :client

    def initialize (service_name, options = {})
      raise ArgumentError,"Please provide a service name" if service_name.nil? || service_name.empty?

      # remember the service name
      @service_name = service_name;

      # Collect the keys relevant to client creation and pass them on to construct
      # the client if one is needed.
      client_keys = [:username, :api_key, :endpoint_url]
      client_options = options.inject({}) do |new_hash, pair|
        if client_keys.include? pair[0]
          new_hash[pair[0]] = pair[1]
        end

        new_hash
      end

      # if the options hash already has a client
      # go ahead and use it
      if options.has_key? :client
        if !client_options.empty?
          raise RuntimeError, "Attempting to construct a service both with a client, and with client initialization options. Only one or the other should be provided."
        end

        @client = options[:client]
      else
        # Accepting client initialization options here
        # is a backward-compatibility feature.

        if $DEBUG
          $stderr.puts %q{
Creating services with Client initialization options is deprecated and may be removed
in a future release. Please change your code to create a client and obtain a service
using either client.service_named('<service_name_here>') or client['<service_name_here>']}
        end

        @client = SoftLayer::Client.new(client_options)
      end

      # this has proven to be very helpful during debugging. It helps prevent infinite recursion
      # when you don't get a method call just right
      @method_missing_call_depth = 0 if $DEBUG
    end

    # Returns a related service with the given service name. The related service
    # will use the same client as this service
    def related_service_named(service_name)
      @client.service_named(service_name)
    end

    # Added here so that the interface of this class matches that
    # of APIParameterFilter.  In APIParameterFilter the target is
    # a service.  In a service, the target is itself.
    def target
      return self
    end

    # Use this as part of a method call chain to identify a particular
    # object as the target of the request. The parameter is the SoftLayer
    # object identifier you are interested in. For example, this call
    # would return the ticket whose ID is 35212
    #
    #   ticket_service.object_with_id(35212).getObject
    #
    def object_with_id(object_of_interest)
      proxy = APIParameterFilter.new(self)
      return proxy.object_with_id(object_of_interest)
    end

    # Use this as part of a method call chain to add an object mask to
    # the request. The arguments to object mask should be well formed
    # Extended Object Mask strings:
    #
    #   ticket_service.object_mask("mask[ticket.createDate, ticket.modifyDate]", "mask(SoftLayer_Some_Type).aProperty").getObject
    #
    # The object_mask becomes part of the request sent to the server
    #
    def object_mask(*args)
      proxy = APIParameterFilter.new(self)
      return proxy.object_mask(*args)
    end

    # Use this as part of a method call chain to reduce the number
    # of results returned from the server. For example, if the server has a list
    # of 100 entities and you only want 5 of them, you can get the first five
    # by using result_limit(0,5). Then for the next 5 you would use
    # result_limit(5,5), then result_limit(10,5) etc.
    def result_limit(offset, limit)
      proxy = APIParameterFilter.new(self)
      return proxy.result_limit(offset, limit)
    end

    # Add an object filter to the request.
    def object_filter(filter)
      proxy = APIParameterFilter.new(self)
      return proxy.object_filter(filter)
    end

    # This is the primary mechanism by which requests are made. If you call
    # the service with a method it doesn't understand, it will send a call to
    # the endpoint for a method of the same name.
    def method_missing(method_name, *args, &block)
      # During development, if you end up with a stray name in some
      # code, you can end up in an infinite recursive loop as method_missing
      # tries to resolve that name (believe me... it happens).
      # This mechanism looks for what it considers to be an unreasonable call
      # depth and kills the loop quickly.
      if($DEBUG)
        @method_missing_call_depth += 1
        if @method_missing_call_depth > 3 # 3 is somewhat arbitrary... really the call depth should only ever be 1
          @method_missing_call_depth = 0
          raise "stop infinite recursion #{method_name}, #{args.inspect}"
        end
      end

      # if we're in debug mode, we put out a little helpful information
      puts "SoftLayer::Service#method_missing called #{method_name}, #{args.inspect}" if $DEBUG

      if(!block && method_name.to_s.match(/[[:alnum:]]+/))
        result = call_softlayer_api_with_params(method_name, nil, args);
      else
        result = super
      end

      if($DEBUG)
        @method_missing_call_depth -= 1
      end

      return result
    end

    # Issue an HTTP request to call the given method from the SoftLayer API with
    # the parameters and arguments given.
    #
    # Parameters are information _about_ the call, the object mask or the
    # particular object in the SoftLayer API you are calling.
    #
    # Arguments are the arguments to the SoftLayer method that you wish to
    # invoke.
    #
    # This is intended to be used in the internal
    # processing of method_missing and need not be called directly.
    def call_softlayer_api_with_params(method_name, parameters, args)
      additional_headers = {};

      # The client knows about authentication, so ask him for the auth headers
      authentication_headers = self.client.authentication_headers
      additional_headers.merge!(authentication_headers)

      if parameters && parameters.server_object_filter
        additional_headers.merge!("#{@service_name}ObjectFilter" => parameters.server_object_filter)
      end

      # Object masks go into the headers too.
      if parameters && parameters.server_object_mask
        object_mask = parameters.server_object_mask
        additional_headers.merge!("SoftLayer_ObjectMask" => { "mask" => object_mask }) unless object_mask.empty?
      end

      # Result limits go into the headers
      if (parameters && parameters.server_result_limit)
        additional_headers.merge!("resultLimit" => { "limit" => parameters.server_result_limit, "offset" => (parameters.server_result_offset || 0) })
      end

      # Add an object id to the headers.
      if parameters && parameters.server_object_id
        additional_headers.merge!("#{@service_name}InitParameters" => { "id" => parameters.server_object_id })
      end

      # This is a workaround for a potential problem that arises from mis-using the
      # API. If you call SoftLayer_Virtual_Guest and you call the getObject method
      # but pass a virtual guest as a parameter, what happens is the getObject method
      # is called through an HTTP POST verb and the API creates a new VirtualServer that
      # is a copy of the one you passed in.
      #
      # The counter-intuitive creation of a new Virtual Server is unexpected and, even worse,
      # is something you can be billed for. To prevent that, we ignore the request
      # body on a "getObject" call and print out a warning.
      if (method_name == :getObject) && (nil != args) && (!args.empty?) then
        $stderr.puts "Warning - The getObject method takes no parameters. The parameters you have provided will be ignored."
        args = nil
      end

      # Collect all the different header pieces into a single hash that
      # will become the first argument to the call.
      call_headers = {
        "headers" => additional_headers
      }

      begin
        call_value = xmlrpc_client.call(method_name.to_s, call_headers, *args)
      rescue XMLRPC::FaultException => e
        puts "A XMLRPC Fault was returned #{e}" if $DEBUG
        raise
      end

      return call_value
    end

    # If this is not defined for Service, then when you print a service object
    # the code will try to convert it to an array and end up calling method_missing
    #
    # We define this here to prevent odd calls to the SoftLayer API
    def to_ary
      nil
    end

    private

    def xmlrpc_client()
      if !@xmlrpc_client
        @xmlrpc_client = XMLRPC::Client.new2(URI.join(@client.endpoint_url,@service_name).to_s, nil, @client.network_timeout)

        # This is a workaround for a bug in later versions of the XML-RPC client in Ruby Core.
        # see https://bugs.ruby-lang.org/issues/8182
        @xmlrpc_client.http_header_extra = {
          "Accept-Encoding" => "identity",
          "User-Agent" => @client.user_agent
        }

        if $DEBUG
          if !@xmlrpc_client.respond_to?(:http)
            class << @xmlrpc_client
              def http
                return @http
              end
            end
          end

          @xmlrpc_client.http.set_debug_output($stderr)
          @xmlrpc_client.http.instance_variable_set(:@verify_mode, OpenSSL::SSL::VERIFY_NONE)
        end # $DEBUG
      end

      @xmlrpc_client
    end
  end # Service class
end # module SoftLayer
