require "xml"
require "../spec_helper"

describe Outlook do
  client = AC::SpecHelper.client
  headers = Mock::Headers.office365_guest

  describe "get /manifest.xml" do
    it "returns an xml manifest" do
      response = client.get("#{OUTLOOK_BASE}/manifest.xml", headers: headers)
      response.status_code.should eq(200)
      XML.parse(response.body).xml?.should be_true
    end
  end
end

OUTLOOK_BASE = Outlook.base_route
