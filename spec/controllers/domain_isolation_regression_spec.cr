require "./helpers/tenant_reach_helper"

module StaffDomainRegressionSpec
  alias Model = PlaceOS::Model

  def self.zone(org : Model::Organisation?)
    Model::Generator.zone.tap(&.organisation_id = org.try(&.id)).save!
  end

  def self.system(org : Model::Organisation?, zone : Model::Zone, feature : String)
    Model::Generator.control_system.tap do |system|
      system.organisation_id = org.try(&.id)
      system.zones = [zone.id.as(String)]
      system.bookable = true
      system.features = Set{feature}
    end.save!
  end

  def self.type_body(category : Model::AssetCategory)
    {name: "domain-type-#{UUID.random}", brand: "Regression", category_id: category.id}.to_json
  end

  def self.clean_categories(categories : Array(Model::AssetCategory))
    Model::AssetType.where(category_id: categories.map(&.id)).each(&.delete)
    categories.each(&.delete)
  end
end

describe "domain isolation regressions" do
  client = AC::SpecHelper.client

  it "falls back to owned rooms and zones only for a single-authority organisation" do
    TenantReachSpec.with_estate do |estate|
      other_org = estate.new_organisation
      estate.authority(other_org)
      local_zone = StaffDomainRegressionSpec.zone(estate.organisation)
      foreign_zone = StaffDomainRegressionSpec.zone(other_org)
      unowned_zone = StaffDomainRegressionSpec.zone(nil)
      local = StaffDomainRegressionSpec.system(estate.organisation, local_zone, "local-feature")
      foreign = StaffDomainRegressionSpec.system(other_org, foreign_zone, "foreign-feature")
      unowned = StaffDomainRegressionSpec.system(nil, unowned_zone, "unowned-feature")
      begin
        response = client.get(Spaces.base_route, headers: estate.headers)
        response.status_code.should eq 200
        JSON.parse(response.body).as_a.map(&.["id"].as_s).should eq [local.id]
        response.headers["X-Total-Count"].should eq "1"
        response = client.get("#{Spaces.base_route}/zones", headers: estate.headers)
        response.status_code.should eq 200
        JSON.parse(response.body).as_a.map(&.["id"].as_s).should eq [local_zone.id]
        JSON.parse(client.get("#{Spaces.base_route}/features", headers: estate.headers).body).as_a.map(&.as_s).should eq ["local-feature"]
        client.get("#{Spaces.base_route}/#{foreign.id}", headers: estate.headers).status_code.should eq 404
        client.get("#{Spaces.base_route}/#{local.id}", headers: estate.headers).status_code.should eq 200
      ensure
        [local, foreign, unowned].each(&.delete)
        [local_zone, foreign_zone, unowned_zone].each(&.delete)
      end
    end
  end

  it "requires org_zone when a domain has no organisation ownership" do
    TenantReachSpec.with_estate do |estate|
      estate.authority.organisation_id = nil
      estate.authority.save!
      response = client.get(Spaces.base_route, headers: estate.headers)
      response.status_code.should eq 501
      response.body.should contain("org_zone")
    end
  end

  it "requires org_zone instead of guessing between domains sharing an organisation" do
    TenantReachSpec.with_estate do |estate|
      estate.authority(estate.organisation)
      response = client.get("#{Spaces.base_route}/zones", headers: estate.headers)
      response.status_code.should eq 501
      response.body.should contain("org_zone")
    end
  end

  it "requires org_zone when an owned room references a foreign zone" do
    TenantReachSpec.with_estate do |estate|
      foreign_zone = StaffDomainRegressionSpec.zone(estate.new_organisation)
      mixed = StaffDomainRegressionSpec.system(estate.organisation, foreign_zone, "mixed-estate")
      begin
        response = client.get(Spaces.base_route, headers: estate.headers)
        response.status_code.should eq 501
        response.body.should contain("org_zone")
      ensure
        mixed.delete
        foreign_zone.delete
      end
    end
  end

  it "preserves explicit org_zone scoping for an existing unowned estate" do
    TenantReachSpec.with_estate do |estate|
      zone = StaffDomainRegressionSpec.zone(nil)
      system = StaffDomainRegressionSpec.system(nil, zone, "configured-estate")
      begin
        estate.authority.organisation_id = nil
        estate.authority.config_will_change!
        estate.authority.config["org_zone"] = JSON::Any.new(zone.id.as(String))
        estate.authority.save!
        response = client.get(Spaces.base_route, headers: estate.headers)
        response.status_code.should eq 200
        JSON.parse(response.body).as_a.map(&.["id"].as_s).should eq [system.id]
        response = client.get("#{Spaces.base_route}/zones", headers: estate.headers)
        JSON.parse(response.body).as_a.map(&.["id"].as_s).should eq [zone.id]
      ensure
        system.delete
        zone.delete
      end
    end
  end

  it "rejects asset type creation in a foreign category" do
    TenantReachSpec.with_estate do |estate|
      foreign = estate.authority(estate.new_organisation)
      category = PlaceOS::Model::Generator.asset_category(foreign).save!
      begin
        response = client.post(AssetTypes.base_route, headers: estate.headers, body: StaffDomainRegressionSpec.type_body(category))
        response.status_code.should eq 403
        PlaceOS::Model::AssetType.where(category_id: category.id).count.should eq 0
      ensure
        StaffDomainRegressionSpec.clean_categories([category])
      end
    end
  end

  it "rejects moving an owned asset type to a foreign category" do
    TenantReachSpec.with_estate do |estate|
      foreign = estate.authority(estate.new_organisation)
      own_category = PlaceOS::Model::Generator.asset_category(estate.authority).save!
      foreign_category = PlaceOS::Model::Generator.asset_category(foreign).save!
      type = PlaceOS::Model::Generator.asset_type(own_category).save!
      begin
        response = client.patch("#{AssetTypes.base_route}/#{type.id}", headers: estate.headers, body: {category_id: foreign_category.id}.to_json)
        response.status_code.should eq 403
        PlaceOS::Model::AssetType.find!(type.id).category_id.should eq own_category.id
      ensure
        StaffDomainRegressionSpec.clean_categories([own_category, foreign_category])
      end
    end
  end

  it "preserves asset type changes within the domain and legacy unowned categories" do
    TenantReachSpec.with_estate do |estate|
      first = PlaceOS::Model::Generator.asset_category(estate.authority).save!
      second = PlaceOS::Model::Generator.asset_category(estate.authority).save!
      legacy = PlaceOS::Model::Generator.asset_category(estate.authority).save!
      # Legacy NULLs are supported by the database, but new model writes require an authority.
      PgORM::Database.connection(&.exec("UPDATE asset_category SET authority_id = NULL WHERE id = $1", legacy.id))
      type = PlaceOS::Model::Generator.asset_type(first).save!
      begin
        client.post(AssetTypes.base_route, headers: estate.headers, body: StaffDomainRegressionSpec.type_body(second)).status_code.should eq 201
        response = client.patch("#{AssetTypes.base_route}/#{type.id}", headers: estate.headers, body: {category_id: second.id}.to_json)
        response.status_code.should eq 200
        PlaceOS::Model::AssetType.find!(type.id).category_id.should eq second.id
        client.post(AssetTypes.base_route, headers: estate.headers, body: StaffDomainRegressionSpec.type_body(legacy)).status_code.should eq 201
      ensure
        StaffDomainRegressionSpec.clean_categories([first, second, legacy])
      end
    end
  end
end
