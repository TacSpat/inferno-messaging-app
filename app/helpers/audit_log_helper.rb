module AuditLogHelper
  def audit_action_display(version)
    item = version.item_type.underscore.humanize.downcase
    item_name = version.object.present? ? extract_name(version) : nil
    name_str = item_name ? " **#{item_name}**" : ""

    case version.event
    when "create"
      label = "created #{item}#{name_str}".html_safe
      color = "bg-green-600/20 text-green-400"
      icon = raw('<svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 4v16m8-8H4"/></svg>')
    when "update"
      label = "updated #{item}#{name_str}".html_safe
      color = "bg-amber-600/20 text-amber-400"
      icon = raw('<svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z"/></svg>')
    when "destroy"
      label = "deleted #{item}#{name_str}".html_safe
      color = "bg-red-600/20 text-red-400"
      icon = raw('<svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"/></svg>')
    else
      label = "#{version.event} #{item}"
      color = "bg-gray-600/20 text-gray-400"
      icon = raw('<svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><circle cx="12" cy="12" r="10" stroke-width="2"/></svg>')
    end

    [label, color, icon]
  end

  private

  def extract_name(version)
    return nil unless version.object.present?
    begin
      obj = YAML.safe_load(version.object, permitted_classes: [Time, Date, ActiveSupport::TimeWithZone, BigDecimal])
      obj["name"] || obj["username"]
    rescue
      nil
    end
  end
end
