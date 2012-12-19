require File.join(File.dirname(__FILE__), 'windows', 'constants')
require File.join(File.dirname(__FILE__), 'windows', 'structs')
require File.join(File.dirname(__FILE__), 'windows', 'functions')

class File
  include Windows::File::Constants
  include Windows::File::Functions
  extend Windows::File::Constants
  extend Windows::File::Structs
  extend Windows::File::Functions

  # The version of the win32-file library
  WIN32_FILE_SECURITY_VERSION = '0.1.0'

  class << self

    # Returns the encryption status of a file as a string. Possible return
    # values are:
    #
    # * encryptable
    # * encrypted
    # * readonly
    # * root directory (i.e. not encryptable)
    # * system fiel (i.e. not encryptable)
    # * unsupported
    # * unknown
    #
    def encryption_status(file)
      wide_file  = file.wincode
      status_ptr = FFI::MemoryPointer.new(:ulong)

      unless FileEncryptionStatusW(wide_file, status_ptr)
        raise SystemCallError.new("FileEncryptionStatus", FFI.errno)
      end

      status = status_ptr.read_ulong

      rvalue = case status
        when FILE_ENCRYPTABLE
          "encryptable"
        when FILE_IS_ENCRYPTED
          "encrypted"
        when FILE_READ_ONLY
          "readonly"
        when FILE_ROOT_DIR
          "root directory"
        when FILE_SYSTEM_ATTR
          "system file"
        when FILE_SYSTEM_NOT_SUPPORTED
          "unsupported"
        else
          "unknown"
      end

      rvalue
    end

    # Returns whether or not the root path of the specified file is
    # encryptable. If a relative path is specified, it will check against
    # the root of the current directory.
    #
    # Be sure to include a trailing slash if specifying a root path.
    #
    # Examples:
    #
    #   p File.encryptable?
    #   p File.encryptable?("D:\\")
    #   p File.encryptable?("C:/foo/bar.txt") # Same as 'C:\'
    #
    def encryptable?(file = nil)
      bool = false
      flags_ptr = FFI::MemoryPointer.new(:ulong)

      if file
        file = File.expand_path(file)
        wide_file = file.wincode

        if !PathIsRootW(wide_file)
          unless PathStripToRootW(wide_file)
            raise SystemCallError.new("PathStripToRoot", FFI.errno)
          end
        end
      else
        wide_file = nil
      end

      unless GetVolumeInformationW(wide_file, nil, 0, nil, nil, flags_ptr, nil, 0)
        raise SystemCallError.new("GetVolumeInformation", FFI.errno)
      end

      flags = flags_ptr.read_ulong

      if flags & FILE_SUPPORTS_ENCRYPTION > 0
        bool = true
      end

      bool
    end

    # Encrypts a file or directory. All data streams in a file are encrypted.
    # All new files created in an encrypted directory are encrypted.
    #
    # The caller must have the FILE_READ_DATA, FILE_WRITE_DATA,
    # FILE_READ_ATTRIBUTES, FILE_WRITE_ATTRIBUTES, and SYNCHRONIZE access
    # rights.
    #
    # Requires exclusive access to the file being encrypted, and will fail if
    # another process is using the file or the file is marked read-only. If the
    # file is compressed the file will be decompressed before encrypting it.
    #
    def encrypt(file)
      unless EncryptFileW(file.wincode)
        raise SystemCallError.new("EncryptFile", FFI.errno)
      end
      self
    end

    # Decrypts an encrypted file or directory.
    #
    # The caller must have the FILE_READ_DATA, FILE_WRITE_DATA,
    # FILE_READ_ATTRIBUTES, FILE_WRITE_ATTRIBUTES, and SYNCHRONIZE access
    # rights.
    #
    # Requires exclusive access to the file being decrypted, and will fail if
    # another process is using the file. If the file is not encrypted an error
    # is NOT raised, it's simply a no-op.
    #
    def decrypt(file)
      unless DecryptFileW(file.wincode, 0)
        raise SystemCallError.new("DecryptFile", FFI.errno)
      end
      self
    end

    # Returns a hash describing the current file permissions for the given
    # file.  The account name is the key, and the value is an integer mask
    # that corresponds to the security permissions for that file.
    #
    # To get a human readable version of the permissions, pass the value to
    # the +File.securities+ method.
    #
    # You may optionally specify a host as the second argument. If no host is
    # specified then the current host is used.
    #
    # Examples:
    #
    #   hash = File.get_permissions('test.txt')
    #
    #   p hash # => {"NT AUTHORITY\\SYSTEM"=>2032127, "BUILTIN\\Administrators"=>2032127, ...}
    #
    #   hash.each{ |name, mask|
    #     p name
    #     p File.securities(mask)
    #   }
    #
    def get_permissions(file, host=nil)
      size_needed_ptr = FFI::MemoryPointer.new(:ulong)
      security_ptr    = FFI::MemoryPointer.new(:ulong)

      wide_file = file.wincode
      wide_host = host ? host.wincode : nil

      # First pass, get the size needed
      bool = GetFileSecurityW(
        wide_file,
        DACL_SECURITY_INFORMATION,
        security_ptr,
        security_ptr.size,
        size_needed_ptr
      )

      errno = FFI.errno

      if !bool && errno != ERROR_INSUFFICIENT_BUFFER
        raise SystemCallError.new("GetFileSecurity", errno)
      end

      size_needed = size_needed_ptr.read_ulong

      security_ptr = FFI::MemoryPointer.new(size_needed)

      # Second pass, this time with the appropriately sized security pointer
      bool = GetFileSecurityW(
        wide_file,
        DACL_SECURITY_INFORMATION,
        security_ptr,
        security_ptr.size,
        size_needed_ptr
      )

      unless bool
        raise SystemCallError.new("GetFileSecurity", FFI.errno)
      end

      control_ptr  = FFI::MemoryPointer.new(:ulong)
      revision_ptr = FFI::MemoryPointer.new(:ulong)

      unless GetSecurityDescriptorControl(security_ptr, control_ptr, revision_ptr)
        raise SystemCallError.new("GetSecurityDescriptorControl", FFI.errno)
      end

      control = control_ptr.read_ulong

      if control & SE_DACL_PRESENT == 0
        raise ArgumentError, "No DACL present: explicit deny all"
      end

      dacl_pptr          = FFI::MemoryPointer.new(:pointer)
      dacl_present_ptr   = FFI::MemoryPointer.new(:bool)
      dacl_defaulted_ptr = FFI::MemoryPointer.new(:ulong)

      val = GetSecurityDescriptorDacl(
        security_ptr,
        dacl_present_ptr,
        dacl_pptr,
        dacl_defaulted_ptr
      )

      if val == 0
        raise SystemCallError.new("GetSecurityDescriptorDacl", FFI.errno)
      end

      acl = ACL.new(dacl_pptr.read_pointer)

      if acl[:AclRevision] == 0
        raise ArgumentError, "DACL is NULL: implicit access grant"
      end

      ace_count  = acl[:AceCount]
      perms_hash = {}

      0.upto(ace_count - 1){ |i|
        ace_pptr = FFI::MemoryPointer.new(:pointer)
        next unless GetAce(acl, i, ace_pptr)

        access = ACCESS_ALLOWED_ACE.new(ace_pptr.read_pointer)

        if access[:Header][:AceType] == ACCESS_ALLOWED_ACE_TYPE
          name = FFI::MemoryPointer.new(:uchar, 260)
          name_size = FFI::MemoryPointer.new(:ulong)
          name_size.write_ulong(name.size)

          domain = FFI::MemoryPointer.new(:uchar, 260)
          domain_size = FFI::MemoryPointer.new(:ulong)
          domain_size.write_ulong(domain.size)

          use_ptr = FFI::MemoryPointer.new(:pointer)

          val = LookupAccountSidW(
            wide_host,
            ace_pptr.read_pointer + 8,
            name,
            name_size,
            domain,
            domain_size,
            use_ptr
          )

          if val == 0
            raise SystemCallError.new("LookupAccountSid", FFI.errno)
          end

          # The x2 multiplier is necessary due to wide char strings.
          name = name.read_string(name_size.read_ulong * 2).delete(0.chr)
          domain = domain.read_string(domain_size.read_ulong * 2).delete(0.chr)

          unless domain.empty?
            name = domain + '\\' + name
          end

          perms_hash[name] = access[:Mask]
        end
      }

      perms_hash
    end

    # Sets the file permissions for the given file name.  The 'permissions'
    # argument is a hash with an account name as the key, and the various
    # permission constants as possible values. The possible constant values
    # are:
    #
    # * FILE_READ_DATA
    # * FILE_WRITE_DATA
    # * FILE_APPEND_DATA
    # * FILE_READ_EA
    # * FILE_WRITE_EA
    # * FILE_EXECUTE
    # * FILE_DELETE_CHILD
    # * FILE_READ_ATTRIBUTES
    # * FILE_WRITE_ATTRIBUTES
    # * STANDARD_RIGHTS_ALL
    # * FULL
    # * READ
    # * ADD
    # * CHANGE
    # * DELETE
    # * READ_CONTROL
    # * WRITE_DAC
    # * WRITE_OWNER
    # * SYNCHRONIZE
    # * STANDARD_RIGHTS_REQUIRED
    # * STANDARD_RIGHTS_READ
    # * STANDARD_RIGHTS_WRITE
    # * STANDARD_RIGHTS_EXECUTE
    # * STANDARD_RIGHTS_ALL
    # * SPECIFIC_RIGHTS_ALL
    # * ACCESS_SYSTEM_SECURITY
    # * MAXIMUM_ALLOWED
    # * GENERIC_READ
    # * GENERIC_WRITE
    # * GENERIC_EXECUTE
    # * GENERIC_ALL
    #
    # Example:
    #
    #   # Set locally
    #   File.set_permissions(file, "userid" => File::GENERIC_ALL)
    #
    #   # Set a remote system
    #   File.set_permissions(file, "host\\userid" => File::GENERIC_ALL)
    #
    def set_permissions(file, perms)
      raise TypeError unless file.is_a?(String)
      raise TypeError unless perms.kind_of?(Hash)

      wide_file = file.wincode

      account_rights = 0
      sec_desc = FFI::MemoryPointer.new(:pointer, SECURITY_DESCRIPTOR_MIN_LENGTH)

      unless InitializeSecurityDescriptor(sec_desc, 1)
        raise SystemCallError.new("InitializeSecurityDescriptor", FFI.errno)
      end

      acl_new = FFI::MemoryPointer.new(ACL, 100)

      unless InitializeAcl(acl_new, acl_new.size, ACL_REVISION2)
        raise SystemCallError.new("InitializeAcl", FFI.errno)
      end

      perms.each{ |account, mask|
        next if mask.nil?

        server, account = account.split("\\")

        if ['BUILTIN', 'NT AUTHORITY'].include?(server.upcase)
          wide_server = nil
        else
          wide_server = server.wincode
        end

        wide_account = account.wincode

        sid = FFI::MemoryPointer.new(:uchar, 1024)
        sid_size = FFI::MemoryPointer.new(:ulong)
        sid_size.write_ulong(sid.size)

        domain = FFI::MemoryPointer.new(:uchar, 260)
        domain_size = FFI::MemoryPointer.new(:ulong)
        domain_size.write_ulong(domain.size)

        use_ptr = FFI::MemoryPointer.new(:ulong)

        val = LookupAccountNameW(
           wide_server,
           wide_account,
           sid,
           sid_size,
           domain,
           domain_size,
           use_ptr
        )

        raise SystemCallError.new("LookupAccountName", FFI.errno) unless val

        all_ace = ACCESS_ALLOWED_ACE2.new

        val = CopySid(
          ALLOW_ACE_LENGTH - ACCESS_ALLOWED_ACE.size,
          all_ace.to_ptr+8,
          sid
        )

        raise SystemCallError.new("CopySid", FFI.errno) unless val

        if (GENERIC_ALL & mask).nonzero?
          account_rights = GENERIC_ALL & mask
        elsif (GENERIC_RIGHTS_CHK & mask).nonzero?
          account_rights = GENERIC_RIGHTS_MASK & mask
        else
          # Do nothing, leave it set to zero.
        end

        all_ace[:Header][:AceFlags] = INHERIT_ONLY_ACE | OBJECT_INHERIT_ACE

        2.times{
          if account_rights != 0
            all_ace[:Header][:AceSize] = 8 + GetLengthSid(sid)
            all_ace[:Mask] = account_rights

            val = AddAce(
              acl_new,
              ACL_REVISION2,
              MAXDWORD,
              all_ace,
              all_ace[:Header][:AceSize]
            )

            raise SystemCallError.new("AddAce", FFI.errno) unless val

            all_ace[:Header][:AceFlags] = CONTAINER_INHERIT_ACE
          else
            all_ace[:Header][:AceFlags] = 0
          end

          account_rights = REST_RIGHTS_MASK & mask
        }
      }

      unless SetSecurityDescriptorDacl(sec_desc, true, acl_new, false)
        raise SystemCallError.new("SetSecurityDescriptorDacl", FFI.errno)
      end

      unless SetFileSecurityW(wide_file, DACL_SECURITY_INFORMATION, sec_desc)
        raise SystemCallError.new("SetFileSecurity", FFI.errno)
      end

      self
    end

    # Returns an array of human-readable strings that correspond to the
    # permission flags.
    #
    # Example:
    #
    #   File.get_permissions('test.txt').each{ |name, mask|
    #     puts name
    #     p File.securities(mask)
    #   }
    #
    def securities(mask)
      sec_array = []

      security_rights = {
        'FULL'    => FULL,
        'DELETE'  => DELETE,
        'READ'    => READ,
        'CHANGE'  => CHANGE,
        'ADD'     => ADD
      }

      if mask == 0
        sec_array.push('NONE')
      else
        if (mask & FULL) ^ FULL == 0
          sec_array.push('FULL')
        else
          security_rights.each{ |string, numeric|
            if (numeric & mask) ^ numeric == 0
              sec_array.push(string)
            end
          }
        end
      end

      sec_array
    end
  end
end
