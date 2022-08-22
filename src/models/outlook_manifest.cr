require "xml"

struct OutlookManifest
  property app_domain : String
  property source_location : String
  property function_file_url : String
  property taskpane_url : String
  property bookings_button_url : String

  def initialize(@app_domain, @source_location, @function_file_url, @taskpane_url, @bookings_button_url)
  end

  def to_xml
    XML.build(indent: "  ") do |xml|
      xml.element("OfficeApp", "xsi:type": "MailApp") do
        xml.element("Id") { xml.text "uuid" }
        xml.element("Version") { xml.text "1.0.0.5" }
        xml.element("ProviderName") { xml.text "PLACEOS" }
        xml.element("DefaultLocale") { xml.text "en-US" }
        xml.element("DisplayName", "DefaultValue": "Room booking")
        xml.element("Description", "DefaultValue": "This add-in allows you to book rooms in your building via the PlaceOS API")
        xml.element("IconUrl", "DefaultValue": "https://s3.ap-southeast-2.amazonaws.com/os.place.tech/outlook-plugin-resources/16x16-01.png")
        xml.element("HighResolutionIconUrl", "DefaultValue": "https://s3.ap-southeast-2.amazonaws.com/os.place.tech/outlook-plugin-resources/80x80-01.png")
        xml.element("SupportUrl", "DefaultValue": "https://place.technology/contact")
        xml.element("AppDomains") do
          xml.element("AppDomain") { xml.text @app_domain }
          xml.element("AppDomain") { xml.text "https://login.microsoftonline.com/" }
        end
        xml.element("Hosts") do
          xml.element("Host", "Name": "Mailbox")
        end
        xml.element("Requirements") do
          xml.element("Sets") do
            xml.element("Set", "Name": "Mailbox", "MinVersion": "1.1")
          end
        end
        xml.element("FormSettings") do
          xml.element("Form", "xsi:type": "ItemRead") do
            xml.element("DesktopSettings") do
              xml.element("SourceLocation", "DefaultValue": @source_location)
              xml.element("RequestedHeight") { xml.text "250" }
            end
          end
        end
        xml.element("Permissions") { xml.text "ReadWriteItem" }
        xml.element("Rule", "xsi:type": "RuleCollection", "Mode": "Or") do
          xml.element("Rule", "xsi:type": "ItemIs", "ItemType": "Message", "FormType": "Read")
        end
        xml.element("DisableEntityHighlighting") { xml.text "false" }
        xml.element("VersionOverrides", "xsi:type": "VersionOverridesV1_0") do
          xml.element("Requirements") do
            xml.element("bt:Sets", "DefaultMinVersion": "1.3") do
              xml.element("bt:Set", "Name": "Mailbox")
            end
          end
          xml.element("Hosts") do
            xml.element("Host", "xsi:type": "MailHost") do
              xml.element("DesktopFormFactor") do
                xml.element("FunctionFile", "resid": "functionFile")
                xml.element("ExtensionPoint", "xsi:type": "AppointmentOrganizerCommandSurface") do
                  xml.element("OfficeTab", "id": "TabDefault") do
                    xml.element("Group", "id": "msgReadGroup") do
                      xml.element("Label", "resid": "GroupLabel")
                      xml.element("Control", "xsi:type": "Button", "id": "msgReadOpenPaneButton") do
                        xml.element("Label", "resid": "TaskpaneButton.Label")
                        xml.element("Supertip") do
                          xml.element("Title", "resid": "TaskpaneButton.Label")
                          xml.element("Description", "resid": "TaskpaneButton.Tooltip")
                        end
                        xml.element("Icon") do
                          xml.element("bt:Image", "size": "16", "resid": "Icon.16x16")
                          xml.element("bt:Image", "size": "32", "resid": "Icon.32x32")
                          xml.element("bt:Image", "size": "80", "resid": "Icon.80x80")
                        end
                        xml.element("Action", "xsi:type": "ShowTaskpane") do
                          xml.element("SourceLocation", "resid": "Taskpane.Url")
                        end
                      end
                      xml.element("Control", "xsi:type": "Button", "id": "BookingsButton") do
                        xml.element("Label", "resid": "BookingsButton.Label")
                        xml.element("Supertip") do
                          xml.element("Title", "resid": "BookingsButton.Label")
                          xml.element("Description", "resid": "BookingsButton.Tooltip")
                        end
                        xml.element("Icon") do
                          xml.element("bt:Image", "size": "16", "resid": "Icon.16x16")
                          xml.element("bt:Image", "size": "32", "resid": "Icon.32x32")
                          xml.element("bt:Image", "size": "80", "resid": "Icon.80x80")
                        end
                        xml.element("Action", "xsi:type": "ShowTaskpane") do
                          xml.element("SourceLocation", "resid": "BookingsButton.Url")
                        end
                      end
                    end
                  end
                end
              end
            end
          end
          xml.element("Resources") do
            xml.element("bt:Images") do
              xml.element("bt:Image", "id": "Icon.16x16", "DefaultValue": "https://s3.ap-southeast-2.amazonaws.com/os.place.tech/outlook-plugin-resources/16x16-01.png")
              xml.element("bt:Image", "id": "Icon.32x32", "DefaultValue": "https://s3.ap-southeast-2.amazonaws.com/os.place.tech/outlook-plugin-resources/32x32-01.png")
              xml.element("bt:Image", "id": "Icon.80x80", "DefaultValue": "https://s3.ap-southeast-2.amazonaws.com/os.place.tech/outlook-plugin-resources/80x80-01.png")
            end
            xml.element("bt:Urls") do
              xml.element("bt:Url", "id": "functionFile", "DefaultValue": @function_file_url)
              xml.element("bt:Url", "id": "Taskpane.Url", "DefaultValue": @taskpane_url)
              xml.element("bt:Url", "id": "BookingsButton.Url", "DefaultValue": @bookings_button_url)
            end
            xml.element("bt:ShortStrings") do
              xml.element("bt:String", "id": "GroupLabel", "DefaultValue": "PlaceOS | Room Booking")
              xml.element("bt:String", "id": "TaskpaneButton.Label", "DefaultValue": "Book a room")
              xml.element("bt:String", "id": "BookingsButton.Label", "DefaultValue": "Upcoming bookings")
            end
            xml.element("bt:LongStrings") do
              xml.element("bt:String", "id": "TaskpaneButton.Tooltip", "DefaultValue": "Opens a pane displaying all available properties.")
              xml.element("bt:String", "id": "BookingsButton.Tooltip", "DefaultValue": "Opens a pane displaying all available properties.")
            end
          end
        end
      end
    end
  end
end
