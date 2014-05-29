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

module SoftLayer
  #
  # This class is used to order a hardware server by providing the full set of
  # configuration options.  Hardware servers may also be ordered with a more 
  # streamlined set of configuration options using the BareMetalInstanceOrder 
  # class.
  #
  # This class roughly Corresponds to the SoftLayer_Container_Product_Order_Hardware_Server
  # data type in the SoftLayer API
  #
  # http://sldn.softlayer.com/reference/datatypes/SoftLayer_Container_Product_Order_Hardware_Server
  #
  class BareMetalServerPackageOrder < Server
    # The following properties are required in a server order.

    # The product package identifying the base configuration for the server.
    # a list of Bare Metal Server product packages is returned by
    # SoftLayer::ProductPackage.bare_metal_server_packages
    attr_reader :package

    # SoftLayer Region Keyname indicating where the server should be provisioned
    # A list of key names is included in the return value from ProductPackage#locations
    attr_accessor :location

    # The hostname of the server being created (i.e. 'sldn' is the hostname of sldn.softlayer.com).
    attr_accessor :hostname

    # The domain of the server being created (i.e. 'softlayer.com' is the domain of sldn.softlayer.com)
    attr_accessor :domain

    # The value of this property should be a hash. The keys of the hash are ProdcutItemCategory
    # codes (like 'os' and 'ram') while the values may either be Integers or objects that respond
    # to the +price_id+ message by returning an Integer.  The Integer values should be the +id+
    # of a SoftLayer_Product_Item_Price representing the configuration option chosen for that category.
    #
    # At a minimum, the configuation_options should include entries for each of the categories
    # required by the package (i.e. those returned from ProductPackage#required_categories)
    attr_accessor :configuration_options

    # The following properties are optional, but allow further fine tuning of
    # the server

    # An array of the ids of SSH keys to install on the server upon provisioning
    # To obtain a list of existing SSH keys, call getSshKeys on the SoftLayer_Account service:
    #     client['Account'].getSshKeys()
    attr_accessor :ssh_key_ids

    # The URI of a script to execute on the server after it has been provisioned. This may be
    # any object which accepts the to_s message.  The resulting string will be passed to SoftLayer API.
    attr_accessor :provision_script_URI

    ##
    # You initialize a BareMetalServerPackageOrder by passing in the package that you
    # are ordering from.
    def initialize(client, package)
      @softlayer_client = client
      @package = package
      @configuration_options = []
    end

    ##
    # Present the order for verification by the SoftLayer ordering system.
    # The order is verified, but not executed.  This should not
    # change the billing of your account.
    #
    # If successful, the SoftLayer API will fill out additional fields
    # in the order for your inspection and return the completed entity.
    #
    # If you add a block to the method call, it will receive the product
    # order template before it is sent to the API.  You may **carefully** make 
    # changes to the template to provide specialized configuration.
    #
    def verify
      product_order = hardware_order
      product_order = yield product_order if block_given?
      softlayer_client["Product_Order"].verifyOrder(product_order)
    end

    ##
    # Submit the order to be executed by the SoftLayer ordering system.
    # If successful this will probably result in additional billing items
    # applied to your account!
    #
    # If successful, the SoftLayer API will fill out additional fields
    # in the order for your inspection and return the completed entity.
    #
    # If you add a block to the method call, it will receive the product
    # order template before it is sent to the API.  You may **carefully** make 
    # changes to the template to provide specialized configuration.
    #
    # The return value of this call is a product order receipt.
    # Because the order must be authorized by sales, and because 
    # hardware provisioning takes times, this routine does not return 
    # the BareMetalServer.
    #
    def place_order!
      product_order = hardware_order
      product_order = yield product_order if block_given?
      softlayer_client["Product_Order"].placeOrder(product_order)
    end

    protected

    ##
    # Construct and return a hash representing a SoftLayer_Container_Product_Order_Hardware_Server
    # based on the configuration options given.
    def hardware_order
      product_order = {
        'packageId' => @package.id,
        'location' => @location,
        'useHourlyPricing' => false,
        'hardware' => {
          'hostname' => @hostname,
          'domain' => @domain
        }
      }

      product_order['sshKeys'] = [{ 'sshKeyIds' => @ssh_key_ids }] if @ssh_key_ids
      product_order['provisionScripts'] = [@provision_script_URI.to_s] if @provision_script_URI

      product_order['prices'] = @configuration_options.collect do |key, value|
        if value.respond_to?(:price_id)
          price_id = value.price_id
        else
          price_id = value.to_i
        end

        { 'id' => price_id }
      end

      product_order
    end
  end # BareMetalServerPackageOrder
end # SoftLayer