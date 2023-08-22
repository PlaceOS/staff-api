require "spec"

# Helper methods for testing controllers (curl, with_server, context)
require "action-controller/spec_helper"
require "placeos-models/spec/generator"

require "faker"
require "timecop"
require "uuid"

# Your application config
# If you have a testing environment, replace this with a test config file
require "../src/config"
require "webmock"

PgORM::Database.parse(ENV["PG_DATABASE_URL"])

Spec.before_suite do
  truncate_db
  # Since almost all specs need need tenant to work
  PlaceOS::Model::Generator.tenant
end

Spec.before_suite do
  # -Dquiet
  {% if flag?(:quiet) %}
    ::Log.setup(:warn)
  {% else %}
    ::Log.setup(:debug)
  {% end %}
end

def get_tenant
  Tenant.find_by(domain: "toby.staff-api.dev")
end

def truncate_db
  Booking.truncate
  EventMetadata.truncate
  Guest.truncate
  Attendee.truncate
  Tenant.truncate
end

Spec.before_each &->WebMock.reset

module Mock
  extend self

  module Token
    extend self

    # office_mock_token
    def office(sys_admin = false, support = false, groups = ["manage", "admin"])
      user = generate_auth_user(sys_admin, support, groups)
      UserJWT.new(
        iss: "staff-api",
        iat: Time.local,
        exp: Time.local + 1.week,
        domain: "toby.staff-api.dev",
        id: user.id,
        scope: [PlaceOS::Model::UserJWT::Scope::PUBLIC],
        user: UserJWT::Metadata.new(
          name: "Toby Carvan",
          email: "dev@acaprojects.com",
          permissions: UserJWT::Permissions::Admin,
          roles: groups
        )
      ).encode
    end

    # office_guest_mock_token
    def office_guest(guest_event_id, system_id)
      UserJWT.new(
        iss: "staff-api",
        iat: Time.local,
        exp: Time.local + 1.week,
        domain: "toby.staff-api.dev",
        id: user.id,
        scope: [PlaceOS::Model::UserJWT::Scope::GUEST],
        user: UserJWT::Metadata.new(
          name: "Jon Jon",
          email: "jon@example.com",
          permissions: UserJWT::Permissions::Admin,
          roles: [guest_event_id, system_id]
        )
      ).encode
    end

    # google_mock_token
    def google(sys_admin = false, support = false, groups = ["manage", "admin"])
      user = generate_auth_user(sys_admin, support, groups)
      UserJWT.new(
        iss: "staff-api",
        iat: Time.local,
        exp: Time.local + 1.week,
        domain: "google.staff-api.dev",
        id: "amit@redant.com.au",
        scope: [PlaceOS::Model::UserJWT::Scope::PUBLIC, PlaceOS::Model::UserJWT::Scope::GUEST],
        user: UserJWT::Metadata.new(
          name: "Amit Gaur",
          email: "amit@redant.com.au",
          permissions: UserJWT::Permissions::Admin,
          roles: groups
        )
      ).encode
    end

    def generate_auth_user(sys_admin, support, groups = [] of String)
      CREATION_LOCK.synchronize do
        org_zone
        authority = PlaceOS::Model::Authority.find_by_domain("toby.staff-api.dev") || PlaceOS::Model::Generator.authority
        authority.domain = "toby.staff-api.dev"
        authority.config_will_change!
        authority.config["org_zone"] = JSON::Any.new("zone-perm-org")
        authority.save!

        scope_list = scopes.try &.join('-', &.to_s)
        group_list = groups.join('-')
        test_user_email = PlaceOS::Model::Email.new("test-#{"admin-" if sys_admin}#{"supp-" if support}scope-#{scope_list}-#{group_list}-rest-api@place.tech")

        PlaceOS::Model::User.where(email: test_user_email.to_s, authority_id: authority.id.as(String)).first? || PlaceOS::Model::Generator.user(authority, support: support, admin: sys_admin).tap do |user|
          user.email = test_user_email
          user.groups = groups
          user.save!
        end
      end
    end

    def org_zone
      zone = PlaceOS::Model::Zone.find?("zone-perm-org")
      return zone if zone

      zone = Model::Generator.zone
      zone.id = "zone-perm-org"
      zone.tags = Set.new ["org"]
      zone.save!

      metadata = Model::Generator.metadata("permissions", zone)
      metadata.details = JSON.parse({
        admin:  ["management"],
        manage: ["concierge"],
      }.to_json)

      metadata.save!
      zone
    end
  end

  module Headers
    extend self

    # Provide some basic headers for office365 auth (office365_guest_headers)
    def office365_guest(guest_event_id = nil, system_id = nil)
      auth = (guest_event_id.nil? && system_id.nil?) ? Mock::Token.office : Mock::Token.office_guest(guest_event_id.not_nil!, system_id.not_nil!)
      HTTP::Headers{
        "Host"          => "toby.staff-api.dev",
        "Authorization" => "Bearer #{auth}",
      }
    end

    def google
      HTTP::Headers{
        "Host"          => "google.staff-api.dev",
        "Authorization" => "Bearer #{Mock::Token.google}",
      }
    end
  end
end

module EventMetadatasHelper
  extend self

  def create_event(tenant_id,
                   id = UUID.random.to_s,
                   event_start = Random.new.rand(5..19).minutes.from_now.to_unix,
                   event_end = Random.new.rand(25..79).minutes.from_now.to_unix,
                   system_id = "sys_id-#{Random.new.rand(500)}",
                   room_email = Faker::Internet.email,
                   host = Faker::Internet.email,
                   ext_data = JSON.parse({"foo": 123}.to_json),
                   ical_uid = "random_uid-#{Random.new.rand(500)}")
    EventMetadata.create!(
      tenant_id: tenant_id,
      system_id: system_id,
      event_id: id,
      host_email: host,
      resource_calendar: room_email,
      event_start: event_start,
      event_end: event_end,
      ext_data: ext_data,
      ical_uid: ical_uid,
    )
  end
end
