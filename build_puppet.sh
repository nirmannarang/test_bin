#!/usr/bin/env bash

set -e -o pipefail

SOURCE_ROOT="$(pwd)"
PACKAGE_NAME="Puppet"
PACKAGE_VERSION="7.10.0"
SERVER_VERSION="7.3.0"
AGENT_VERSION="7.10.0"
RUBY_VERSION="2.7"
RUBY_FULL_VERSION="2.7.3"
JFFI_VERSION="1.3.5"
JRUBY_VERSION="9.2.17.0"
JAVA_PROVIDED="AdoptJDK11_hotspot"
FORCE="false"
LOG_FILE="$SOURCE_ROOT/logs/${PACKAGE_NAME}-${PACKAGE_VERSION}-$(date +"%F-%T").log"

JDK11_URL="https://github.com/adoptium/temurin11-binaries/releases/download/jdk-11.0.12%2B7/OpenJDK11U-jdk_s390x_linux_hotspot_11.0.12_7.tar.gz"

trap cleanup 0 1 2 ERR

#Check if directory exists
if [ ! -d "$SOURCE_ROOT/logs" ]; then
	mkdir -p "$SOURCE_ROOT/logs"
fi

source "/etc/os-release"

function checkPrequisites() {
	printf -- "Checking Prequisites\n"

	if [ -z "$USEAS" ]; then
		printf "Option -s must be specified with argument server/agent \n"
		exit
	fi

	if command -v "sudo" >/dev/null; then
		printf -- 'Sudo : Yes\n' >>"$LOG_FILE"
	else
		printf -- 'Sudo : No \n' >>"$LOG_FILE"
		printf -- 'Install sudo from repository using apt, yum or zypper based on your distro. \n'
		exit 1
	fi

	if [[ "$JAVA_PROVIDED" != "AdoptJDK11_hotspot" && "$JAVA_PROVIDED" != "OpenJDK11" ]]; then
		printf "$JAVA_PROVIDED is not supported, Please use valid java from {AdoptJDK11_hotspot, OpenJDK11} only"
		exit 1
	fi

	if [[ "$FORCE" == "true" ]]; then
		printf -- 'Force attribute provided hence continuing with install without confirmation message\n' |& tee -a "$LOG_FILE"
	else
		# Ask user for prerequisite installation
		printf -- "\nAs part of the installation , dependencies would be installed/upgraded.\n"
		while true; do
			read -r -p "Do you want to continue (y/n) ? :  " yn
			case $yn in
			[Yy]*)
				printf -- 'User responded with Yes. \n' >>"$LOG_FILE"
				break
				;;
			[Nn]*) exit ;;
			*) echo "Please provide confirmation to proceed." ;;
			esac
		done
	fi
}

function cleanup() {
	if [[ -f "ruby"-${RUBY_FULL_VERSION}.tar.gz ]]; then
		sudo rm "ruby"-${RUBY_FULL_VERSION}.tar.gz
	fi
	if [[ -f apache-ant-1.10.11-bin.tar.gz ]]; then
		sudo rm apache-ant-1.10.11-bin.tar.gz
	fi
	if [[ -f adoptjdk.tar.gz ]]; then
		sudo rm adoptjdk.tar.gz
	fi
	if [[ -f "jffi"-${JFFI_VERSION}.tar.gz ]]; then
		sudo rm "jffi"-${JFFI_VERSION}.tar.gz
	fi
	printf -- '\nCleaned up the artifacts.\n' >>"$LOG_FILE"
}

function buildAgent() {
	#Install Puppet
	cd "$SOURCE_ROOT"
	sudo -E env PATH="$PATH" gem install puppet -v $AGENT_VERSION
	printf -- 'Completed Puppet agent setup \n'
}

function buildServer() {
	printf -- 'Build puppetserver and Installation started \n'

	if [[ "$DISTRO" == "rhel-7.8" || "$DISTRO" == "rhel-7.9" ]]; then
		cd $SOURCE_ROOT
		wget http://archive.apache.org/dist/ant/binaries/apache-ant-1.10.11-bin.tar.gz
		tar -xvf apache-ant-1.10.11-bin.tar.gz
		export ANT_HOME=$SOURCE_ROOT/apache-ant-1.10.11
		export PATH=$ANT_HOME/bin:$PATH
	fi

	if [[ "$JAVA_PROVIDED" == "AdoptJDK11_hotspot" ]]; then
		# Install AdoptOpenJDK 11 (With Hotspot)
		cd $SOURCE_ROOT
		wget -O adoptjdk.tar.gz ${JDK11_URL}
		mkdir -p adoptjdk11
		tar -zxvf adoptjdk.tar.gz -C adoptjdk11/ --strip-components 1
		export JAVA_HOME=$SOURCE_ROOT/adoptjdk11
		printf -- "Installation of AdoptOpenJDK 11 (With Hotspot) is successful\n" >> "$LOG_FILE"

	elif [[ "$JAVA_PROVIDED" == "OpenJDK11" ]]; then
		if [[ "${ID}" == "ubuntu" ]]; then
			sudo DEBIAN_FRONTEND=noninteractive apt-get install -y openjdk-11-jdk
			export JAVA_HOME=/usr/lib/jvm/java-11-openjdk-s390x
		elif [[ "${ID}" == "rhel" ]]; then
			sudo yum install -y java-11-openjdk-devel
			export JAVA_HOME=/usr/lib/jvm/java-11-openjdk
		fi
		printf -- "Installation of OpenJDK 11 is successful\n" >> "$LOG_FILE"

	else
		printf "$JAVA_PROVIDED is not supported, Please use valid java from {AdoptJDK11_hotspot, OpenJDK11} only"
		exit 1
	fi

	export PATH=$JAVA_HOME/bin:$PATH

	if  [[  "$DISTRO"  =~  "rhel"  ]]; then
		printf -- 'Build jffi lib \n'
		cd $SOURCE_ROOT
		wget https://github.com/jnr/jffi/archive/jffi-$JFFI_VERSION.tar.gz
		tar -xzf jffi-$JFFI_VERSION.tar.gz
		cd jffi-jffi-$JFFI_VERSION
		ant jar

		export LD_LIBRARY_PATH=${SOURCE_ROOT}/jffi-jffi-${JFFI_VERSION}/build/jni/:${SOURCE_ROOT}/jffi-jffi-${JFFI_VERSION}/build/jni/libffi-s390x-linux/.libs${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}
	fi

	printf -- 'Install lein \n'
	cd $SOURCE_ROOT
	wget https://raw.githubusercontent.com/technomancy/leiningen/stable/bin/lein
	chmod +x lein
	sudo mv lein /usr/bin/

	printf -- 'Get puppetserver \n'
	cd $SOURCE_ROOT
	git clone --recursive --branch $SERVER_VERSION git://github.com/puppetlabs/puppetserver
	cd puppetserver

	printf -- 'Setup config files \n'
	export LANG="en_US.UTF-8"
	./dev-setup

	printf -- 'Update JRuby jars\n'
	cd $SOURCE_ROOT
	unzip -q ~/.m2/repository/org/jruby/jruby-stdlib/$JRUBY_VERSION/jruby-stdlib-$JRUBY_VERSION.jar
	cp META-INF/jruby.home/lib/ruby/stdlib/ffi/platform/powerpc-aix/syslog.rb META-INF/jruby.home/lib/ruby/stdlib/ffi/platform/s390x-linux/
	zip -qr jruby-stdlib.jar META-INF
	cp jruby-stdlib.jar ~/.m2/repository/org/jruby/jruby-stdlib/$JRUBY_VERSION/jruby-stdlib-$JRUBY_VERSION.jar
	sudo rm -rf META-INF jruby-stdlib.jar

	printf -- 'Completed Puppet server setup \n'

	runTest

}

function runTest() {
	set +e
  	if [[ "$TEST" == "true" ]]; then
    	printf -- "TEST Flag is set, continue with running test \n"
		printf -- "Running clojure test suite \n"
		cd $SOURCE_ROOT/puppetserver
		RUBYOPT='-W0' PUPPETSERVER_HEAP_SIZE=6G lein test
		printf -- "Running jruby test suite \n"
		cd $SOURCE_ROOT/puppetserver
		rake spec		
      	printf -- "Test suite execution completed \n"
  	fi
  	set -e
}

function configureAndInstall() {
	printf -- 'Configuration and Installation started \n'
	# Download and install Ruby
	cd "$SOURCE_ROOT"
	wget http://cache.ruby-lang.org/pub/ruby/$RUBY_VERSION/ruby-$RUBY_FULL_VERSION.tar.gz
	# Avoid conflict when script runs twice
	rm -rf ruby-$RUBY_FULL_VERSION
	tar -xzf ruby-$RUBY_FULL_VERSION.tar.gz
	cd ruby-$RUBY_FULL_VERSION
	./configure && make && sudo -E env PATH="$PATH" make install

	# Install bundler
	sudo -E env PATH="$PATH" gem install bundler rake-compiler

	# Build server or agent
	if [ "$USEAS" = "server" ]; then
		buildServer
	elif [ "$USEAS" = "agent" ]; then
		buildAgent
	else
		printf -- "please enter the argument (server/agent) with option -s "
		exit
	fi
}

function logDetails() {
	printf -- '**************************** SYSTEM DETAILS *************************************************************\n' >"$LOG_FILE"

	if [ -f "/etc/os-release" ]; then
		cat "/etc/os-release" >>"$LOG_FILE"
	fi

	cat /proc/version >>"$LOG_FILE"
	printf -- '*********************************************************************************************************\n' >>"$LOG_FILE"

	printf -- "Detected %s \n" "$PRETTY_NAME"
	printf -- "Request details : PACKAGE NAME= %s , VERSION= %s \n" "$PACKAGE_NAME" "$PACKAGE_VERSION" |& tee -a "$LOG_FILE"

}

# Print the usage message
function printHelp() {
	echo
	echo "Usage: "
	echo "  build_puppet.sh [-s server/agent] [-j Java to be used from {AdoptJDK11_hotspot, OpenJDK11}] "
	echo
}

while getopts "h?dyt?s:j:" opt; do
	case "$opt" in
	h | \?)
		printHelp
		exit 0
		;;
	d)
		set -x
		;;
	y)
		FORCE="true"
		;;
	t)
		TEST="true"
		;;
	s)
		export USEAS=$OPTARG
		;;
	j)
		export JAVA_PROVIDED="$OPTARG"
		;;
	esac
done

function gettingStarted() {
	# Need to retrieve $JAVA_HOME for final output
	if [[ "$JAVA_PROVIDED" == "AdoptJDK11_hotspot" ]]; then
		JAVA_HOME=$SOURCE_ROOT/adoptjdk11
	elif [[ "$JAVA_PROVIDED" == "OpenJDK11" ]]; then
		if [[ "${ID}" == "ubuntu" ]]; then
			JAVA_HOME=/usr/lib/jvm/java-11-openjdk-s390x
		elif [[ "${ID}" == "rhel" ]]; then
			JAVA_HOME=/usr/lib/jvm/java-11-openjdk
		fi
	fi

	printf -- "Puppet installed successfully. \n"
	if [ "$USEAS" = "server" ]; then
		printf -- '\n'
		printf -- "     To run Puppet server, set the environment variables below and follow from step 2.10 in build instructions.\n"
		printf -- "     	export JAVA_HOME=$JAVA_HOME\n"
		printf -- "     	export PATH=\$JAVA_HOME/bin:\$PATH\n"
		if [[ "${ID}" == "ubuntu" ]]; then
			printf -- "	 export LD_LIBRARY_PATH=/usr/lib/s390x-linux-gnu/jni/\${LD_LIBRARY_PATH:+:\${LD_LIBRARY_PATH}}"
		elif [[ "${ID}" == "rhel" ]]; then
			printf -- "	 export LD_LIBRARY_PATH=${SOURCE_ROOT}/jffi-jffi-${JFFI_VERSION}/build/jni/:${SOURCE_ROOT}/jffi-jffi-${JFFI_VERSION}/build/jni/libffi-s390x-linux/.libs\${LD_LIBRARY_PATH:+:\${LD_LIBRARY_PATH}}"
		fi
		printf -- '\n'
	elif [ "$USEAS" = "agent" ]; then
		printf -- '\n'
		printf -- "     To run Puppet agent, follow from step 3.4 in build instructions.\n"
		printf -- '\n'
		printf -- "More information can be found here : https://puppetlabs.com/\n"
		printf -- '\n'
	fi
}


###############################################################################################################

logDetails
DISTRO="$ID-$VERSION_ID"
checkPrequisites #Check Prequisites

if [[ "$USEAS" == "server" ]]; then
	case "$DISTRO" in
	"ubuntu-18.04" | "ubuntu-20.04")
		printf -- "Installing %s Server %s for %s \n" "$PACKAGE_NAME" "$SERVER_VERSION" "$DISTRO" |& tee -a "$LOG_FILE"
		printf -- "Installing the dependencies for $PACKAGE_NAME from repository \n" |& tee -a "$LOG_FILE"
		sudo apt-get update >/dev/null
		sudo apt-get install -y g++ tar git make wget locales locales-all unzip ant zip libjffi-jni libssl-dev zlib1g-dev libreadline-dev libgdbm-dev libgdbm-compat-dev |& tee -a "$LOG_FILE"
		export LD_LIBRARY_PATH=/usr/lib/s390x-linux-gnu/jni/${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}
		configureAndInstall |& tee -a "$LOG_FILE"
		;;

	"rhel-7.8" | "rhel-7.9")
		printf -- "Installing %s Server %s for %s \n" "$PACKAGE_NAME" "$SERVER_VERSION" "$DISTRO" |& tee -a "$LOG_FILE"
		printf -- "Installing the dependencies for $PACKAGE_NAME from repository \n" |& tee -a "$LOG_FILE"
		sudo yum install -y gcc-c++ tar unzip openssl-devel make git wget zip readline-devel gdbm-devel texinfo |& tee -a "$LOG_FILE"
		configureAndInstall |& tee -a "$LOG_FILE"
		;;
	
	"rhel-8.2" | "rhel-8.3" | "rhel-8.4")
		printf -- "Installing %s Server %s for %s \n" "$PACKAGE_NAME" "$SERVER_VERSION" "$DISTRO" |& tee -a "$LOG_FILE"
		printf -- "Installing the dependencies for $PACKAGE_NAME from repository \n" |& tee -a "$LOG_FILE"
		sudo yum install -y gcc-c++ tar unzip openssl-devel make git wget zip ant readline-devel gdbm-devel diffutils texinfo |& tee -a "$LOG_FILE"
		configureAndInstall |& tee -a "$LOG_FILE"
		;;

	*)
		printf -- "%s not supported \n" "$DISTRO" |& tee -a "$LOG_FILE"
		exit 1
		;;
	esac

elif [[ "$USEAS" == "agent" ]]; then
	case "$DISTRO" in
	"ubuntu-18.04" | "ubuntu-20.04" | "ubuntu-21.04")
		printf -- "Installing %s Agent %s for %s \n" "$PACKAGE_NAME" "$AGENT_VERSION" "$DISTRO" |& tee -a "$LOG_FILE"
		printf -- "Installing the dependencies for $PACKAGE_NAME from repository \n" |& tee -a "$LOG_FILE"
		sudo apt-get update >/dev/null
		sudo apt-get install -y g++ tar make wget libssl-dev zlib1g-dev libreadline-dev libgdbm-dev libgdbm-compat-dev |& tee -a "$LOG_FILE"
		configureAndInstall |& tee -a "$LOG_FILE"
		;;

	"rhel-7.8" | "rhel-7.9")
		printf -- "Installing %s Agent %s for %s \n" "$PACKAGE_NAME" "$AGENT_VERSION" "$DISTRO" |& tee -a "$LOG_FILE"
		printf -- "Installing the dependencies for $PACKAGE_NAME from repository \n" |& tee -a "$LOG_FILE"
		sudo yum install -y gcc-c++ tar openssl-devel make wget readline-devel gdbm-devel |& tee -a "$LOG_FILE"
		configureAndInstall |& tee -a "$LOG_FILE"
		;;

	"rhel-8.2" | "rhel-8.3" | "rhel-8.4")
		printf -- "Installing %s Agent %s for %s \n" "$PACKAGE_NAME" "$AGENT_VERSION" "$DISTRO" |& tee -a "$LOG_FILE"
		printf -- "Installing the dependencies for $PACKAGE_NAME from repository \n" |& tee -a "$LOG_FILE"
		sudo yum install -y gcc-c++ tar openssl-devel make wget readline-devel gdbm-devel |& tee -a "$LOG_FILE"
		configureAndInstall |& tee -a "$LOG_FILE"
		;;

	"sles-12.5")
		printf -- "Installing %s Agent %s for %s \n" "$PACKAGE_NAME" "$AGENT_VERSION" "$DISTRO" |& tee -a "$LOG_FILE"
		printf -- "Installing the dependencies for $PACKAGE_NAME from repository \n" |& tee -a "$LOG_FILE"
		sudo zypper install -y gcc-c++ tar openssl-devel make wget gzip awk gzip readline-devel gdbm-devel |& tee -a "$LOG_FILE"
		configureAndInstall |& tee -a "$LOG_FILE"
		;;

	"sles-15.2" | "sles-15.3")
		printf -- "Installing %s Agent %s for %s \n" "$PACKAGE_NAME" "$AGENT_VERSION" "$DISTRO" |& tee -a "$LOG_FILE"
		printf -- "Installing the dependencies for $PACKAGE_NAME from repository \n" |& tee -a "$LOG_FILE"
		sudo zypper install -y gcc-c++ tar gzip make wget readline-devel gdbm-devel awk libopenssl-devel zlib-devel |& tee -a "$LOG_FILE"
		configureAndInstall |& tee -a "$LOG_FILE"
		;;

	*)
		printf -- "%s not supported \n" "$DISTRO" |& tee -a "$LOG_FILE"
		exit 1
		;;
	esac

else
	printf -- "please enter the argument (server/agent) with option -s "
	exit
fi

gettingStarted |& tee -a "$LOG_FILE"
