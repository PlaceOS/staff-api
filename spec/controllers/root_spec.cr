require "../spec_helper"

with_server do
  it "should check version" do
    result = curl("GET", "/api/staff/v1/version")
    result.status_code.should eq 200
    PlaceOS::Model::Version.from_json(result.body).service.should eq "StaffAPI"
  end
end
