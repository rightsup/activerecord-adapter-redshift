module ActiveRecordRedshiftAdapter
  class Railtie < ::Rails::Railtie
    initializer "activerecord-redshift-adapter.setup" do
      ActiveSupport.on_load(:active_record) do
        ActiveRecord::ConnectionAdapters.register('redshift', 'ActiveRecord::ConnectionAdapters::RedshiftAdapter')
      end
    end
  end
end
