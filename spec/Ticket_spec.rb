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

$LOAD_PATH << File.expand_path(File.join(File.dirname(__FILE__), "../lib"))

require 'rubygems'
require 'softlayer_api'
require 'rspec'

require 'spec_helper'

describe SoftLayer::Ticket do
	it "retrieves ticket subjects from API once" do
    fakeTicketSubjects = fixture_from_json("ticket_subjects")

	  mock_client = SoftLayer::Client.new(:username => "fakeuser", :api_key=> 'fakekey')
      allow(mock_client).to receive(:[]) do |service_name|
        service_name.should == "Ticket_Subject"

        mock_service = SoftLayer::Service.new("SoftLayer_Ticket_Subject", :client => mock_client)
        expect(mock_service).to receive(:getAllObjects).once.and_return(fakeTicketSubjects)
        expect(mock_service).to_not receive(:call_softlayer_api_with_params)

        mock_service
      end

      SoftLayer::Ticket.ticket_subjects(mock_client).should be(fakeTicketSubjects)

      # call for the subjects again which should NOT re-request them from the client
      # (so :getAllObjects on the service should not be called again)
      SoftLayer::Ticket.ticket_subjects(mock_client).should be(fakeTicketSubjects)
	end
end