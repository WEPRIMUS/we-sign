# frozen_string_literal: true

module Desk
  class SettingsController < BaseController
    def edit
      @users = User.active.where(account_id: current_account.id).order(:first_name)
    end

    def update # rubocop:disable Metrics/AbcSize
      attrs = params.require(:setting).permit(:approval_required, :sender_signs_on_approval, :expiry_warning_days,
                                              :reminder_days, :own_party_names, approver_user_ids: [],
                                                                                own_profile: Desk::Setting::PROFILE_KEYS)

      desk_settings.assign_attributes(
        approval_required: attrs[:approval_required] == '1',
        sender_signs_on_approval: attrs[:sender_signs_on_approval] == '1',
        expiry_warning_days: attrs[:expiry_warning_days].to_i,
        reminder_days: attrs[:reminder_days].to_s.scan(/\d+/).map(&:to_i),
        own_party_names: attrs[:own_party_names].to_s.lines.map(&:squish).compact_blank,
        approver_user_ids: User.where(account_id: current_account.id, id: Array(attrs[:approver_user_ids])).ids,
        own_profile: attrs[:own_profile].to_h.transform_values { |v| v.to_s.strip }.compact_blank
      )

      if desk_settings.save
        Desk::Event.log!(account_id: current_account.id, action: 'settings changed', actor: 'person',
                         user: current_user, data: { changed: desk_settings.previous_changes.except('updated_at') })
        redirect_to edit_desk_settings_path, notice: 'Saved.'
      else
        @users = User.active.where(account_id: current_account.id).order(:first_name)
        render :edit, status: :unprocessable_content
      end
    end
  end
end
