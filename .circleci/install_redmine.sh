#!/bin/bash

set -uex

REDMINE_DIR=/tmp/redmine

if [ ! -d $REDMINE_DIR ]; then
  curl http://www.redmine.org/releases/$REDMINE.tar.gz | tar zx -C /tmp
  mv /tmp/$REDMINE $REDMINE_DIR
  cd $REDMINE_DIR

  cat << HERE > config/database.yml
development:
  adapter: sqlite3
  database: db/test.sqlite3
test:
  adapter: sqlite3
  database: db/test.sqlite3
HERE

  ln -s ~/project/Gemfile.local $REDMINE_DIR
  ln -s ~/project $REDMINE_DIR/plugins/$PLUGIN_NAME
fi
