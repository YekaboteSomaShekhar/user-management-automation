### User Management Automation Task

## Purpose & design

create_users.sh automates onboarding of Linux user accounts from a simple text file. Each input line has the format:

username1;group1,group2,group3`

### Step-by-step explanation:

+ Root check
The script aborts if not run as root (creates users and sets passwords require root).

+ Prepare directories and files
Ensures /var/secure exists (700) and /var/secure/user_passwords.txt exists (600). Ensures /var/log/user_management.log exists (600). Ownership set to root:root.

+ Generating secure passwords
generate_password() prefers openssl rand -base64 then filters to allowed characters; if openssl is missing, it falls back to /dev/urandom + tr. Ensures exactly 12 characters.

+ Processing input lines

+ Each line is trimmed; split at ; into username and groups.

+ Additional groups are split on commas and trimmed.

+ Groups handling
ensure_group() checks with getent group and runs groupadd only if the group doesn't exist.

+ User creation / update

+ If user does not exist: useradd -m -g username -s /bin/bash username.

+ If user exists: script attempts to set primary group and proceeds to ensure groups and home directory properties.

+ Supplementary groups
Uses usermod -aG to append groups without removing existing ones.

+ Home directory
Ensures the home exists, sets ownership to username:username, and permissions 700.

+ Set password
Uses chpasswd to set the generated password.

+ Save credentials
Appends username:password to /var/secure/user_passwords.txt. The script uses flock when available to avoid concurrent write races.

+ Logging
All important steps (success/failure/warnings) are appended to /var/log/user_management.log with timestamps.

### Example

Given `users_list.txt`:

#### new hires
+ light; sudo,dev,www-data
+ siyoni; sudo
+ manoj; dev,www-data

#### To run the script:

`sudo ./create_users.sh users_list.txt`

#### Expected output:

+ User 'light' processed. Credentials stored in /var/secure/user_passwords.txt (root-only).
+ User 'siyoni' processed. Credentials stored in /var/secure/user_passwords.txt (root-only).
+ User 'manoj' processed. Credentials stored in /var/secure/user_passwords.txt (root-only).
