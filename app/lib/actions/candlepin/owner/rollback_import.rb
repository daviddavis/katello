module Actions
  module Candlepin
    module Owner
      class RollbackImport < Dynflow::Action::Reverting
        def plan(parent_action)
          binding.pry
          label = parent_action.input[:organization][:label]
          imports = ::Katello::Resources::Candlepin::Owner.imports(label)
          if imports.length == 1
            plan_action(Owner::DestroyImports, :label => label)
          end
        end

        def humanized_name
          _("Manifest Import Rollback")
        end
      end
    end
  end
end
