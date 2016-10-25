module Actions
  module Candlepin
    module Owner
      class DestroyImports < Candlepin::Abstract
        input_format do
          param :label
        end

        def run
          output[:response] = ::Katello::Resources::Candlepin::Owner.destroy_imports(input[:label], true)
          ::Katello::Subscription.import_all
          ::Katello::Pool.import_all
        end
      end
    end
  end
end
