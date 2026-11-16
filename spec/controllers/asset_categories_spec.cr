require "../spec_helper"
require "./helpers/api_spec_helper"

# asserts a successful asset categories index response and extracts the returned ids
def asset_category_index_ids(result) : Array(String)
  result.status_code.should eq 200
  Array(Hash(String, JSON::Any))
    .from_json(result.body)
    .map(&.["id"].to_s)
end

describe AssetCategories do
  before_each { clear_group_tables }

  ApiSpec.test_404(AssetCategories.base_route, model_name: PlaceOS::Model::AssetCategory.table_name, headers: ApiSpec::Authentication.headers, clz: Int64)

  describe "index", tags: "search" do
    ApiSpec.test_base_index(PlaceOS::Model::AssetCategory, AssetCategories)

    it "filters categories by hidden status, including hidden=false", tags: "search" do
      _, headers = ApiSpec::Authentication.authentication

      visible = PlaceOS::Model::Generator.asset_category
      visible.hidden = false
      visible.save!

      concealed = PlaceOS::Model::Generator.asset_category
      concealed.hidden = true
      concealed.save!

      base = AssetCategories.base_route.rstrip('/')

      # hidden=false returns only non-hidden categories (the Elasticsearch
      # implementation silently ignored `hidden=false`; this pins the fix)
      ids = asset_category_index_ids(client.get("#{base}?hidden=false&limit=1000", headers: headers))
      ids.should contain(visible.id)
      ids.should_not contain(concealed.id)

      # hidden=true returns only hidden categories
      ids = asset_category_index_ids(client.get("#{base}?hidden=true&limit=1000", headers: headers))
      ids.should contain(concealed.id)
      ids.should_not contain(visible.id)

      # no hidden param returns all categories
      ids = asset_category_index_ids(client.get("#{base}?limit=1000", headers: headers))
      ids.should contain(visible.id)
      ids.should contain(concealed.id)

      visible.destroy
      concealed.destroy
    end
  end

  describe "CRUD operations", tags: "crud" do
    ApiSpec.test_crd(PlaceOS::Model::AssetCategory, AssetCategories)
    ApiSpec.test_crd(PlaceOS::Model::AssetCategory, AssetCategories, sys_admin: false, support: false, groups: ["management"])
    ApiSpec.test_crd(PlaceOS::Model::AssetCategory, AssetCategories, sys_admin: false, support: false, groups: ["concierge"])

    it "fails to create if a regular user" do
      body = PlaceOS::Model::Generator.asset_category.to_json
      result = client.post(
        AssetCategories.base_route,
        body: body,
        headers: ApiSpec::Authentication.headers(sys_admin: false, support: false)
      )
      result.status_code.should eq 403
    end
  end

  describe "authority ownership" do
    it "sets the authority_id from the current authority on create" do
      body = PlaceOS::Model::Generator.asset_category.to_json
      result = client.post(
        AssetCategories.base_route,
        body: body,
        headers: ApiSpec::Authentication.headers(sys_admin: true, support: false),
      )
      result.status_code.should eq 201

      created = PlaceOS::Model::AssetCategory.from_trusted_json(result.body)
      authority = PlaceOS::Model::Authority.find_by_domain("localhost").not_nil!
      created.authority_id.should eq authority.id
      created.destroy
    end

    it "rejects updates to a category owned by another authority" do
      other_authority = PlaceOS::Model::Generator.authority(domain: "https://other-asset-cat.example.com").save!
      asset_category = PlaceOS::Model::Generator.asset_category(other_authority).save!

      result = client.patch(
        path: "#{AssetCategories.base_route}/#{asset_category.id}",
        body: {name: "renamed-#{random_name}"}.to_json,
        headers: ApiSpec::Authentication.headers(sys_admin: true, support: false),
      )
      result.status_code.should eq 403

      asset_category.destroy
      other_authority.destroy
    end

    it "rejects destroy of a category owned by another authority" do
      other_authority = PlaceOS::Model::Generator.authority(domain: "https://other-asset-cat-destroy.example.com").save!
      asset_category = PlaceOS::Model::Generator.asset_category(other_authority).save!

      result = client.delete(
        path: "#{AssetCategories.base_route}/#{asset_category.id}",
        headers: ApiSpec::Authentication.headers(sys_admin: true, support: false),
      )
      result.status_code.should eq 403
      PlaceOS::Model::AssetCategory.find?(asset_category.id).should_not be_nil

      asset_category.destroy
      other_authority.destroy
    end

    it "adopts a legacy category with no authority on update" do
      asset_category = PlaceOS::Model::Generator.asset_category.save!
      # simulate a legacy record predating the authority_id column
      asset_category.update_fields(authority_id: nil)

      result = client.patch(
        path: "#{AssetCategories.base_route}/#{asset_category.id}",
        body: {name: "renamed-#{random_name}"}.to_json,
        headers: ApiSpec::Authentication.headers(sys_admin: true, support: false),
      )
      result.success?.should be_true

      authority = PlaceOS::Model::Authority.find_by_domain("localhost").not_nil!
      PlaceOS::Model::AssetCategory.find!(asset_category.id).authority_id.should eq authority.id
      asset_category.destroy
    end
  end

  describe "authority scoping" do
    it "only lists and shows the caller authority's categories, and legacy ones,, admins included" do
      _, headers = ApiSpec::Authentication.authentication(sys_admin: false, support: false)
      other = PlaceOS::Model::Generator.authority(domain: "https://category-scope-#{random_name}.example.com").save!
      mine = PlaceOS::Model::Generator.asset_category.save!
      theirs = PlaceOS::Model::Generator.asset_category(other).save!
      legacy = PlaceOS::Model::Generator.asset_category.save!
      PlaceOS::Model::AssetCategory.where(id: legacy.id).update_all(authority_id: nil)
      path = "#{AssetCategories.base_route.rstrip('/')}?limit=10000"

      ids = JSON.parse(client.get(path, headers: headers).body).as_a.map(&.["id"].as_s)
      ids.should contain(mine.id)
      ids.should contain(legacy.id)
      ids.should_not contain(theirs.id)

      client.get(File.join(AssetCategories.base_route, theirs.id.to_s), headers: headers).status_code.should eq 404
      client.get(File.join(AssetCategories.base_route, legacy.id.to_s), headers: headers).status_code.should eq 200

      # admin and support users are held to their own authority too
      ids = JSON.parse(client.get(path, headers: ApiSpec::Authentication.headers).body).as_a.map(&.["id"].as_s)
      ids.should_not contain(theirs.id)
      client.get(File.join(AssetCategories.base_route, theirs.id.to_s), headers: ApiSpec::Authentication.headers).status_code.should eq 404

      mine.destroy
      legacy.destroy
      theirs.destroy
      other.destroy
    end
  end

  describe "scopes" do
    ApiSpec.test_controller_scope(AssetCategories)
  end

  describe "support-subsystem permissions" do
    it "allows POST for a support user with Create on the org zone (both sides)" do
      authority = PlaceOS::Model::Authority.find_by_domain("localhost").not_nil!
      user, headers = ApiSpec::Authentication.authentication(sys_admin: false, support: false)
      org_zone = ApiSpec::Authentication.org_zone

      group = PlaceOS::Model::Generator.group(authority: authority, subsystems: ["support"]).save!
      PlaceOS::Model::Generator.group_user(user: user, group: group, permissions: PlaceOS::Model::Permissions::Create).save!
      PlaceOS::Model::Generator.group_zone(group: group, zone: org_zone, permissions: PlaceOS::Model::Permissions::Create).save!

      body = PlaceOS::Model::Generator.asset_category.to_json
      result = client.post(AssetCategories.base_route, body: body, headers: headers)
      result.status_code.should eq 201

      PlaceOS::Model::AssetCategory.from_trusted_json(result.body).destroy
    end

    it "rejects POST when the support user only has Read on the org zone" do
      authority = PlaceOS::Model::Authority.find_by_domain("localhost").not_nil!
      user, headers = ApiSpec::Authentication.authentication(sys_admin: false, support: false)
      org_zone = ApiSpec::Authentication.org_zone

      group = PlaceOS::Model::Generator.group(authority: authority, subsystems: ["support"]).save!
      PlaceOS::Model::Generator.group_user(user: user, group: group, permissions: PlaceOS::Model::Permissions::Read).save!
      PlaceOS::Model::Generator.group_zone(group: group, zone: org_zone, permissions: PlaceOS::Model::Permissions::Read).save!

      body = PlaceOS::Model::Generator.asset_category.to_json
      result = client.post(AssetCategories.base_route, body: body, headers: headers)
      result.status_code.should eq 403
    end

    it "requires Update on both sides to PATCH an asset category" do
      authority = PlaceOS::Model::Authority.find_by_domain("localhost").not_nil!
      user, headers = ApiSpec::Authentication.authentication(sys_admin: false, support: false)
      org_zone = ApiSpec::Authentication.org_zone

      asset_category = PlaceOS::Model::Generator.asset_category.save!
      group = PlaceOS::Model::Generator.group(authority: authority, subsystems: ["support"]).save!
      PlaceOS::Model::Generator.group_user(user: user, group: group, permissions: PlaceOS::Model::Permissions::Update).save!
      PlaceOS::Model::Generator.group_zone(group: group, zone: org_zone, permissions: PlaceOS::Model::Permissions::Update).save!

      result = client.patch(
        path: "#{AssetCategories.base_route}/#{asset_category.id}",
        body: {name: "renamed-#{random_name}"}.to_json,
        headers: headers,
      )
      result.success?.should be_true
      asset_category.destroy
    end

    it "rejects PATCH when the support user only has Create on the org zone" do
      authority = PlaceOS::Model::Authority.find_by_domain("localhost").not_nil!
      user, headers = ApiSpec::Authentication.authentication(sys_admin: false, support: false)
      org_zone = ApiSpec::Authentication.org_zone

      asset_category = PlaceOS::Model::Generator.asset_category.save!
      group = PlaceOS::Model::Generator.group(authority: authority, subsystems: ["support"]).save!
      PlaceOS::Model::Generator.group_user(user: user, group: group, permissions: PlaceOS::Model::Permissions::Create).save!
      PlaceOS::Model::Generator.group_zone(group: group, zone: org_zone, permissions: PlaceOS::Model::Permissions::Create).save!

      result = client.patch(
        path: "#{AssetCategories.base_route}/#{asset_category.id}",
        body: {name: "renamed-#{random_name}"}.to_json,
        headers: headers,
      )
      result.status_code.should eq 403
      asset_category.destroy
    end

    it "requires Delete on both sides to DELETE an asset category" do
      authority = PlaceOS::Model::Authority.find_by_domain("localhost").not_nil!
      user, headers = ApiSpec::Authentication.authentication(sys_admin: false, support: false)
      org_zone = ApiSpec::Authentication.org_zone

      asset_category = PlaceOS::Model::Generator.asset_category.save!
      group = PlaceOS::Model::Generator.group(authority: authority, subsystems: ["support"]).save!
      PlaceOS::Model::Generator.group_user(user: user, group: group, permissions: PlaceOS::Model::Permissions::Delete).save!
      PlaceOS::Model::Generator.group_zone(group: group, zone: org_zone, permissions: PlaceOS::Model::Permissions::Delete).save!

      result = client.delete(path: "#{AssetCategories.base_route}/#{asset_category.id}", headers: headers)
      result.success?.should be_true
      PlaceOS::Model::AssetCategory.find?(asset_category.id).should be_nil
    end

    it "rejects DELETE when the support user only has Update on the org zone" do
      authority = PlaceOS::Model::Authority.find_by_domain("localhost").not_nil!
      user, headers = ApiSpec::Authentication.authentication(sys_admin: false, support: false)
      org_zone = ApiSpec::Authentication.org_zone

      asset_category = PlaceOS::Model::Generator.asset_category.save!
      group = PlaceOS::Model::Generator.group(authority: authority, subsystems: ["support"]).save!
      PlaceOS::Model::Generator.group_user(user: user, group: group, permissions: PlaceOS::Model::Permissions::Update).save!
      PlaceOS::Model::Generator.group_zone(group: group, zone: org_zone, permissions: PlaceOS::Model::Permissions::Update).save!

      result = client.delete(path: "#{AssetCategories.base_route}/#{asset_category.id}", headers: headers)
      result.status_code.should eq 403
      asset_category.destroy
    end

    it "rejects DELETE of another authority's category even with Delete on the org zone" do
      authority = PlaceOS::Model::Authority.find_by_domain("localhost").not_nil!
      user, headers = ApiSpec::Authentication.authentication(sys_admin: false, support: false)
      org_zone = ApiSpec::Authentication.org_zone

      other_authority = PlaceOS::Model::Generator.authority(domain: "https://other-asset-cat-support.example.com").save!
      asset_category = PlaceOS::Model::Generator.asset_category(other_authority).save!

      group = PlaceOS::Model::Generator.group(authority: authority, subsystems: ["support"]).save!
      PlaceOS::Model::Generator.group_user(user: user, group: group, permissions: PlaceOS::Model::Permissions::Delete).save!
      PlaceOS::Model::Generator.group_zone(group: group, zone: org_zone, permissions: PlaceOS::Model::Permissions::Delete).save!

      result = client.delete(path: "#{AssetCategories.base_route}/#{asset_category.id}", headers: headers)
      result.status_code.should eq 403
      PlaceOS::Model::AssetCategory.find?(asset_category.id).should_not be_nil

      asset_category.destroy
      other_authority.destroy
    end

    it "allows a support-JWT user to POST regardless of group grants" do
      body = PlaceOS::Model::Generator.asset_category.to_json
      result = client.post(
        AssetCategories.base_route,
        body: body,
        headers: ApiSpec::Authentication.headers(sys_admin: false, support: true),
      )
      result.status_code.should eq 201
      PlaceOS::Model::AssetCategory.from_trusted_json(result.body).destroy
    end

    it "allows an admin-JWT user to POST regardless of group grants" do
      body = PlaceOS::Model::Generator.asset_category.to_json
      result = client.post(
        AssetCategories.base_route,
        body: body,
        headers: ApiSpec::Authentication.headers(sys_admin: true, support: false),
      )
      result.status_code.should eq 201
      PlaceOS::Model::AssetCategory.from_trusted_json(result.body).destroy
    end
  end
end
