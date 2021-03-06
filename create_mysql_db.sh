#!/bin/bash

usage() {
	cat >/dev/stderr <<USAGE
Initializes a local (non-sudo) MySQL database data directory, creates a connection script
and connects to the database. By default, it creates two directories, 'data' and 'conf',
under the given base directory, with the database's data and configuration files,
respectively.

Usage: $0 [--database=<database-name>] <base-dir>
e.g. zcat mydb_backup.sql.gz | $0 --database=mydb .

Options:
    -D, --database NAME  Create the database NAME.
    -P, --port PORT      Setup the server to use PORT for listening. (default: 'none';
                         that is, avoid using TCP-IP entirely, relying solely on Unix sockets instead).
    -x, --drop-first     Drop the given database before creating it (only valid with -D).
    -c, --connect        Connect to the given database.
                         This is useful for importing data right after creation.
    -o, --optimize       Optimize database(s) after connection using mysqlcheck --optimize.
                         If a database name is given, optimization is done only for
                         that database.
    -r, --character-set  Server character set (default: utf8)
    -l, --collation      Server collation (default: utf8_bin)
    -h, --help           Show usage information and quit.
USAGE
}
fail() {
	echo "Error: $@" && exit 1
}
fail_usage() {
	usage && fail "$@"
}

db_name=
port=none
connect=0
drop_first=0
optimize=0
# see also: https://dev.mysql.com/doc/refman/5.7/en/charset-configuration.html
character_set=utf8
collation=utf8_bin

# read command line options
! OPTS="$(getopt -o D:P:xcor:l:h --long database:,port:,drop-first,connect,optimize,character-set,collation,help -n "$0" -- "$@")" && fail_usage "Invalid option."
eval set -- "${OPTS}"
while true; do
	case "$1" in
		-D | --database      ) db_name="$2"; shift 2 ;;
		-P | --port          ) port="$2"   ; shift 2 ;;
		-x | --drop-first    ) drop_first=1; shift ;;
		-c | --connect       ) connect=1   ; shift ;;
		-o | --optimize      ) optimize=1  ; shift ;;
		-h | --help          ) usage; shift; exit  ;;
		-r | --character-set ) character_set=utf8; shift 2 ;;
		-l | --collation     ) collation=utf8_bin; shift 2 ;;
		-- ) shift; break ;;
		* ) shift ;;
	esac
done
(
cat <<OPTIONS
setting	Database	${db_name}
setting	Port	${port}
setting	Character set	${character_set}
setting	Collation	${collation}
flag	Drop first	${drop_first}
flag	Connect	${connect}
flag	Optimize	${optimize}
OPTIONS
) | awk -F'\t' '{
	is_flag = ($1=="flag");
	printf "    %15s%s %s\n", $2, (is_flag? "?" : ":"), (is_flag? ($3=="1"? "Yes" : "No") : $3)
	}'

# read mandatory command line arguments
if [ "$#" != 1 ]; then
	fail_usage "Invalid number of arguments"
	exit 1
fi

base_dir=$(readlink -f $1)

data_dir=${base_dir}/data
conf_dir=${base_dir}/conf
cnf=${conf_dir}/mysql.cnf
sock=$( echo "${cnf}" | sed 's/\.cnf/.sock/' )
connect_script=${base_dir}/mysql.sh

mkdir -p ${data_dir} ${conf_dir}

# Create a configuration file if one is missing
if [ ! -e "${cnf}" ]; then
	echo "Creating configuration file..."
################################################################# conf file start
(
	cat <<CNF
[mysqld]
datadir=${data_dir}
socket=${sock}
max-connections=10000
innodb-file-per-table=1
character-set-server=${character_set}
collation-server=${collation}
CNF
	if [ -n "${port}" ]; then
		if [ "${port}" == "none" ]; then
			echo "skip-networking"
		else
			echo "port=${port}"
		fi
	fi
) > ${cnf}
################################################################# conf file end

fi # if [ ! -e "${cnf}" ]

# If the database was never initialized (no mysql subdir), initialize it
if [ ! -d ${data_dir}/mysql ]; then
	echo "Creating barebones database..."
	mysqld --defaults-file=${cnf}  --datadir=${data_dir} --explicit-defaults-for-timestamp --initialize-insecure || \
		(echo "Error while creating database. Make sure AppArmor isn't set up to block mysqld from " \
			"this directory; see http://informationideas.com/news/2010/04/15/changing-mysql-data-directory-require-change-to-apparmor/"; exit 1) 2>&1 | \
		tee mysqld_initialize.log
	#mysql_install_db --defaults-file=${cnf} --datadir=${data_dir} --user=$(whoami)
fi # if [ ! -d ${data_dir}/mysql ]

# Create a connection script if one is missing
if [ ! -e "${connect_script}" ]; then

	echo "Creating connection script..."

	# root_pwd=$(grep "A temporary password is generated for" mysqld_initialize.log | awk '{print $NF}')
	# if [ -n $root_pwd ]; then
	#	root_pwd_opt="--password=${root_pwd}"
	# else
	#	root_pwd_opt="--password"
	# fi
	root_pwd_opt=""

################################################################# heredoc start
	cat > "${connect_script}" <<SCRIPT
#!/bin/bash
#
# Usage: ${connect_script} [mysql options ...] [< SQL_FILE] > [> OUT_FILE]
#
# Runs a MySQL client (mysql) to connect to the MySQL server (mysqld)
# associated with the database located at:
#     "${base_dir}"
#
# The script first ensures that a MySQL server instance is running
# (according to whether the sock-file exists; see script code for details).
# If the script had to start the MySQL server instance, it will terminate
# this instance once the client operation has ended.
#
# All options, standard input and standard output are redirected to
# the MySQL client, so one may use this script as one would use the MySQL
# client without having to specify the target database (if you do specify
# the target database, that would be awfully confusing to the MySQL client).
#
# This script was generated by the following command:
#     "$0" "$@"
# run when the current directory was:
#     $(pwd)
# at $(date).
#
cnf=${cnf}
sock=${sock}
log=\$(echo "\${cnf}" | sed 's/\.cnf\$/.log/')
started_mysqld=0

if [ ! -e \${sock} ]; then
	echo "Starting mysqld..." | tee --append \${log} > /dev/stderr
	stdbuf -o0 -i0 -e0 /usr/sbin/mysqld --defaults-file=\${cnf} < /dev/null >> \${log} 2>&1 &
	mysqld_pid=\$!
	started_mysqld=1

	echo "Server process: \${mysqld_pid}" > /dev/stderr
fi

echo "Waiting for connection to become available..." > /dev/stderr
attempts=0
while [ ! -e \${sock} ] && ! nc -zU \${sock} 2> /dev/null; do
	attempts=\$(( \${attempts} + 1 ))
	if [ \${attempts} -gt 20 ]; then
		echo "Connection to MySQL server cannot be established. Not trying anymore." > /dev/stderr
		# still allow the rest of the script to run
		break
	fi
	sleep 0.5
done

/usr/bin/mysql \\
    --defaults-file=\${cnf} \\
    --user=root ${root_pwd_opt} \\
    --socket=\${sock} "\$@"

if [ "\${started_mysqld}" == "1" ]; then
	echo "Stopping server..." | tee --append \${log} > /dev/stderr
	kill \${mysqld_pid}
	sleep 3
fi
SCRIPT
################################################################# heredoc end

chmod +x "${connect_script}"

fi # if [ ! -e "${connect_script}" ]

# Create the database if it doesn't exist
if [ -n "${db_name}" ] && [ "${drop_first}" == 1 -o ! -d "${data_dir}/${db_name}" ]; then
	echo "Creating database..."

	(
		if [ "${drop_first}" == "1" ]; then
			echo "drop database if exists \'${db_name}\';"
		fi
		echo "create database if not exists \`${db_name}\`;"
	) | "${connect_script}"
fi

# Connect to the database server, optionally using the given database
if [ "${connect}" == 1 ]; then
	if [ -n "${db_name}" ]; then
		echo "Connecting to database ${db_name} and redirecting stdin..."
		"${connect_script}" --database=${db_name}
	else
		echo "Connecting to database and redirecting stdin..."
		"${connect_script}"
	fi
fi

if [ "${optimize}" == 1 ]; then
	target_db="--all-databases"
	if [ -n "${db_name}" ]; then
		target_db="${db_name}"
	fi

	/usr/sbin/mysqld --defaults-file=${cnf} < /dev/null > /dev/null 2>&1 &
	mysqld_pid=$!
	echo "Server process: \${mysqld_pid}"
	sleep 2
	echo "Optimizing tables..."
	mysqlcheck --user=root --sock=conf/mysql.sock --optimize ${target_db}
	echo "Stopping server..."
	kill ${mysqld_pid}
	sleep 3
fi
