#
# Copyright (c) 2014 SoftLayer Technologies, Inc. All rights reserved.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.
#

require 'rubygems'
require 'savon'

class String
  # This code was taken from ActiveSupport in Rails and modified just a bit to remove
  # parts that would handle non-english text.  The odd name is there specifically to
  # prevent collisions with other methods
  def sl_camelcase_to_underscore
    word = self.dup
    word.gsub!(/([A-Z\d]+)([A-Z][a-z])/,'\1_\2')
    word.gsub!(/([a-z\d])([A-Z])/,'\1_\2')
    word.tr!("-", "_")
    word.downcase!
    word
  end
end

module SoftLayer
  # A subclass of Exception with nothing new provided.  This simply provides
  # a unique type for exceptions from the SoftLayer API
  class SoftLayerAPIException < RuntimeError
  end

  # = SoftLayer API Service
  #
  # Instances of this class are the runtime representation of 
  # services in the SoftLayer API. They handle communication with
  # the SoftLayer servers.
  # 
  # You typically should not need to create services directly.
  # instead, you should be creating a client and then using it to 
  # obtain individual services.  For example:
  #
  # client = SoftLayer::Client.new(:username => "Joe", :api_key=>"feeddeadbeefbadfood...")
  # account_service = client.service_named("Account") # returns the SoftLayer_Account service
  # account_service = client['Account'] # Exactly the same as above
  #
  # For backward compatibility, a service can be constructed by passing 
  # client initialization options, however if you do so you will need to
  # prepend the "SoftLayer_" on the front of the service name.  For Example:
  #
  #   account_service = SoftLayer::Service("SoftLayer_Account", 
  #     :username=>"<your user name here>" 
  #     :api_key=>"<your api key here>")
  #
  # A service communicates with the SoftLayer API through the 
  # Savon client gem.  You may pass options to the Savon client 
  # using the option named :savon_client_options.  The value of this 
  # key is expected to be a hash of options (for example,
  # :savon_client_options => { :log => true}).
  #
  # Once you have a service, you can invoke methods in the service like this:
  #
  #   account_service.getOpenTickets
  #   => {... lots of information here representing the list of open tickets ...}
  #
  class Service
    # The name of the service that this object calls. Cannot be emtpy or nil.
    attr_reader :service_name
    attr_reader :client
  
    def initialize(service_name, options = {})
      raise SoftLayerAPIException.new("Please provide a service name") if service_name.nil? || service_name.empty?

      # remember the service name
      @service_name = service_name;

      # if the options hash already has a client
      # go ahead and use it
      if options.has_key? :client
        @client = options[:client]
      else
        # Accepting client initialization options here
        # is a backward-compatibility feature.
        
        if $DEBUG
          $stderr.puts %q{ 
Creating services with Client initialization options is deprecated and may be removed 
in a future release.  Please change your code to create a client and obtain a service 
using either client.service_named('<service_name_here>') or client['<service_name_here>']}
        end
        
        # Collect the keys relevant to client creation and pass them on to construct
        # the client
        client_keys = [:username, :api_key, :endpoint_url]
        client_options = options.inject({}) do |new_hash, pair| 
          if client_keys.include? pair[0]
            new_hash[pair[0]] = pair[1]
            new_hash
          end
        end

        if client && !options.empty?
          raise SoftlayerAPIException.new("Attempting to construct a service both with a client, and with client initialization options.  Only one or the other should be provided")
        end

        @client = SoftLayer::Client.new(client_options)
      end


      # construct the savon soap object used by this service
      construct_soap_service(options[:savon_client_options])

      # this has proven to be very helpful during debugging.  It helps prevent infinite recursion
      # when you don't get a method call just right
      @method_missing_call_depth = 0 if $DEBUG
    end

    # Use this as part of a method call chain to identify a particular
    # object as the target of the request. The parameter is the SoftLayer
    # object identifier you are interested in. For example, this call
    # would return the ticket whose ID is 35212
    #
    #   ticket_service.object_with_id(35212).getObject
    #
    def object_with_id(object_of_interest)
      proxy = APIParameterFilter.new
      proxy.target = self

      return proxy.object_with_id(object_of_interest)
    end

    # Use this as part of a method call chain to add an object mask to
    # the request.The arguments to object mask should be the strings
    # that are the keys of the mask:
    #
    #   ticket_service.object_mask("createDate", "modifyDate").getObject
    #
    # Before being used, the string passed will be url-encoded by this
    # routine. (i.e. there is no need to url-encode the strings beforehand)
    #
    # As an implementation detail, the object_mask becomes part of the
    # query on the url sent to the API server
    #
    def object_mask(*args)
      proxy = APIParameterFilter.new
      proxy.target = self

      return proxy.object_mask(*args)
    end

    def result_limit(offset, limit)
      proxy = APIParameterFilter.new
      proxy.target = self
      return proxy.result_limit(offset, limit)
    end
    
    # This is the primary mechanism by which requests are made. If you call
    # the service with a method it doesn't understand, it will send a call to
    # the endpoint for a method of the same name.
    #
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

      result = call_softlayer_api_with_params(method_name, nil, args, &block);

      if($DEBUG)
        @method_missing_call_depth -= 1
      end

      return result
    end
    
    # When SOAP returns an array it actually returns a structure with information about the type
    # of the array included.  What this does is recursively traverse a response and replaces
    # all these structures with their actual array values.
    def fix_soap_arrays(response_value)
      if response_value.kind_of? Hash 
        if response_value.has_key?("@SOAP_ENC:arrayType") && response_value.has_key?("item") then
          response_value = response_value["item"]
        else
          response_value.each { |key, value| response_value[key] = fix_soap_arrays(value) }
        end
      end

      if response_value.kind_of? Array then
        response_value.each_with_index { | value, index | response_value[index] = fix_soap_arrays(value) }
      end
      
      response_value
    end
    
    def fix_argument_arrays(arguments_value)
      if arguments_value.kind_of? Hash then
        arguments_value.each { |key, value| arguments_value[key] = fix_argument_arrays(value) }
      end
      
      if arguments_value.kind_of? Array then
        result = {}
        arguments_value.each_with_index { |item, index| result["item#{index}"] = fix_argument_arrays(item) }
        arguments_value = result
      end
      
      arguments_value
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
    def call_softlayer_api_with_params(method_name, parameters, args, &block)
      additional_headers = {};

      if(parameters && parameters.server_object_id)        
        additional_headers = {"tns:#{@service_name}InitParameters" => { "id" => parameters.server_object_id}}
      end

      if(parameters && parameters.server_object_mask)
        object_mask = SoftLayer::ObjectMask.new()
        object_mask.subproperties = parameters.server_object_mask

        additional_headers.merge!({ "tns:SoftLayer_ObjectMask" => { "mask" => object_mask.to_sl_object_mask } })
      end

      if (parameters && parameters.server_result_limit)
        additional_headers.merge!("tns:resultLimit" => { "offset" => (parameters.server_result_offset || 0), "limit" => parameters.server_result_limit })
      end
      
      # This is a workaround for a potential problem that arises from mis-using the
      # API.  If you call SoftLayer_Virtual_Guest and you call the getObject method
      # but pass a virtual guest as a parameter, what happens is the getObject method
      # is called through an HTTP POST verb and the API creates a new CCI that is a copy
      # of the one you passed in.
      #
      # The counter-intuitive creation of a new CCI is unexpected and, even worse,
      # is something you can be billed for.  To prevent that, we ignore the request
      # body on a "getObject" call and print out a warning.
      if (method_name == :getObject) && (nil != args) && (!args.empty?) then
        $stderr.puts "Warning - The getObject method takes no parameters. The parameters you have provided will be ignored."
        args = nil
      end

      # convert the arguments array into a SOAP array structure and stuff that in as the message\
      if(args && !args.empty?)
        call_arguments = { :message => fix_argument_arrays(args) }
      else
        call_arguments = {}
      end
      
      # if there were any additional soap headers that were added as part of this call,
      # add those in too.
      if(additional_headers && !additional_headers.empty?)
        call_arguments.merge!(:soap_header => additional_headers)
      end

      # convert the camel-case method name to a underscore based symbol
      soap_symbol = method_name.to_s.sl_camelcase_to_underscore.to_sym

      soap_result = @_soap_service.call(soap_symbol, call_arguments)  
      soap_return_value = fix_soap_arrays(soap_result.body["#{method_name}Response"]["#{method_name}Return"]) 

      return soap_return_value
    end
    
    def to_ary
      nil
    end
    
    private
    
    def construct_soap_service(user_savon_options)
      # Create the SOAP client object that will be used for calls to this service
      savon_options = {
				:wsdl => (@client.endpoint_url + @service_name + '?wsdl'),
        :convert_request_keys_to => :none,
        :convert_response_tags_to => :none,
        :log => $DEBUG || false,
				:soap_header => {'tns:authenticate' => 
          { 'username' => @client.username, 
            "apiKey" => @client.api_key } }
      }

      # if the caller provided any savon options, put them into the client options hash
      if user_savon_options then
        savon_options = savon_options.merge(user_savon_options)
      end

      @_soap_service = Savon.client(savon_options);
    end
    
  end # Service class
end # module SoftLayer