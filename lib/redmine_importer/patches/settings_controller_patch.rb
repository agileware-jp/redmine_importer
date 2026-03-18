# frozen_string_literal: true

module RedmineImporter
  module Patches
    module SettingsControllerPatch
      def plugin
        plugin = Redmine::Plugin.find(params[:id])
        if request.post? && plugin.id == :redmine_importer
          settings = params[:settings] ? params[:settings].permit!.to_h : {}
          max_csv_rows = settings['max_csv_rows'].to_s.strip

          unless max_csv_rows.match?(/\A[1-9]\d*\z/)
            flash[:error] = l(:error_max_csv_rows_invalid)
            redirect_to plugin_settings_path(plugin)
            return
          end
        end

        super
      end
    end
  end
end
