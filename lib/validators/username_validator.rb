#
# Copyright 2011 Red Hat, Inc.
#
# This software is licensed to you under the GNU General Public
# License as published by the Free Software Foundation; either version
# 2 of the License (GPLv2) or (at your option) any later version.
# There is NO WARRANTY for this software, express or implied,
# including the implied warranties of MERCHANTABILITY,
# NON-INFRINGEMENT, or FITNESS FOR A PARTICULAR PURPOSE. You should
# have received a copy of GPLv2 along with this software; if not, see
# http://www.gnu.org/licenses/old-licenses/gpl-2.0.txt.

module Validators
  class UsernameValidator < ActiveModel::EachValidator
    def validate_each(record, attribute, value)
      if value
        if Katello.config.katello?
          record.errors[attribute] << _("cannot contain characters other than ASCII values") unless value.ascii_only?
        end
        KatelloNameFormatValidator.validate_length(record, attribute, value, 64, 3)
      end
    end
  end
end