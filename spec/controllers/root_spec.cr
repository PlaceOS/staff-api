require "../spec_helper"

with_server do
  # it "health checks" do
  #   result = curl("GET", "/api/frontends/v1/")
  #   result.success?.should be_true
  # end

  it "should check version" do
    result = curl("GET", "/api/frontends/v1/version")
    result.status_code.should eq 200
    PlaceOS::Model::Version.from_json(result.body).service.should eq "frontends"
  end
end
