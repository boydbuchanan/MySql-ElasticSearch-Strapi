# Syncronize A MySQL database table with ElasticSearch using Logstash
The purpose of this guide is to create a table in our mysql database that will track creations, updates and deletes. We use triggers on the table we want to index to push data into an index table (a log table) that Logstash will use to keep it's index up to date.

Strapi creates a user database table with every installation. This example will update the database to enable logstash to Create, Update and Delete users in the search index.

### Strapi Not required
This can be applied to any database, strapi is what I was implementing this for at the time I started this.

## Summary

There's a lot of steps here, but if you skip the setup parts this only boils down to adding database triggers to the table you want to update, creating the index table for those triggers, and the logstash pipeline to read the index table to propagate the data.

## Install Strapi & Dockerize

```bash
npx create-strapi-app@latest elastic-strapi
cd elastic-strapi
npm install
npx @strapi-community/dockerize
```

Before continuing, ensure you can run strapi with Docker.

## Add ELK Stack

Add the following to the docker-compose.yml file

```yml
services:
  elasticsearch:
    image: docker.elastic.co/elasticsearch/elasticsearch:7.9.3
    container_name: elastic-search
    environment:
      - discovery.type=single-node
      - bootstrap.memory_lock=true
      - "ES_JAVA_OPTS=-Xms512m -Xmx512m"
    volumes:
      - ./volumes/elasticsearch:/usr/share/elasticsearch/data
    logging:
        driver: "json-file"
        options:
            max-size: "10k"
            max-file: "10"

  logstash:
    build:
      context: .
      dockerfile: Dockerfile.logstash
    container_name: elastic-logstash
    depends_on:
      - elastic-strapiDB
      - elasticsearch
    volumes:
      - ./volumes/logstash/pipeline/:/usr/share/logstash/pipeline/
      - ./volumes/logstash/config/pipelines.yml:/usr/share/logstash/config/pipelines.yml

  kibana:
    image: docker.elastic.co/kibana/kibana:7.9.3
    container_name: elastic-kibana
    environment:
      - "ELASTICSEARCH_URL=http://elasticsearch:9200"
      - "SERVER_NAME=127.0.0.1"
    ports:
      - 5601:5601
    depends_on:
      - elasticsearch
```

Create Logstash dockerfile (Dockerfile.logstash) and add the following

```dockerfile
FROM docker.elastic.co/logstash/logstash:7.9.3
# Download JDBC connector for Logstash
RUN curl -L --output "mysql-connector-java-8.0.22.tar.gz" "https://dev.mysql.com/get/Downloads/Connector-J/mysql-connector-java-8.0.22.tar.gz" \
    && tar -xf "mysql-connector-java-8.0.22.tar.gz" "mysql-connector-java-8.0.22/mysql-connector-java-8.0.22.jar" \
    && mv "mysql-connector-java-8.0.22/mysql-connector-java-8.0.22.jar" "mysql-connector-java-8.0.22.jar" \
    && rm -r "mysql-connector-java-8.0.22" "mysql-connector-java-8.0.22.tar.gz"
ENTRYPOINT ["/usr/local/bin/docker-entrypoint"]
```

## Add Logstash Files

Create the following folders/files
```
volumes/logstash/config/pipelines.yml
volumes/logstash/pipeline/incremental.conf
```
Add the following to pipelines.yml
```yml
- pipeline.id: incremental
  path.config: "/usr/share/logstash/pipeline/incremental.conf"
```
Add the following to the conf

```
input {
  jdbc {
    jdbc_driver_library => "/usr/share/logstash/mysql-connector-java-8.0.22.jar"
    jdbc_driver_class => "com.mysql.jdbc.Driver"
    jdbc_connection_string => "jdbc:mysql://localhost:3306"
    jdbc_user => "root"
    jdbc_password => "rootpassword"
    schedule => "*/5 * * * * *" # every 5 seconds
    use_column_value => true
    tracking_column => "index_action_id"
    tracking_column_type => "numeric"
    # select from index table, then join users. Otherwise, if a user was deleted, the join will fail and the row will be ignored
    statement => "SELECT * FROM strapi.up_users_index_action a LEFT JOIN strapi.up_users u ON u.id = a.user_id WHERE (a.index_action_id > :sql_last_value AND a.action_time < NOW()) ORDER BY a.index_action_id"
  }
}
filter {
  if [action_type] == "create" or [action_type] == "update" {
    mutate { add_field => { "[@metadata][action]" => "index" } }
  } else if [action_type] == "delete" {
    mutate { add_field => { "[@metadata][action]" => "delete" } }
  }

  mutate {
    remove_field => ["action_type", "@version", "@timestamp", "password", "*_token"]
  }
}
output {
  elasticsearch {
    hosts => ["http://elasticsearch:9200"]
    index => "up_users"
    action => "%{[@metadata][action]}"
    # map to index table user id, otherwise if a user was deleted, this would be empty
    document_id => "%{user_id}"
  }
}
```
Let's go over the Conf to see how and why we're updating the database. Starting with input, first off make certain the user that jdbc uses has the correct permissions and update your connection string.

### Input 
- tracking_column: Indicates which column to store in the :sql_last_value variable
- statement: Select our index actions database, join the user information accordingly. The where clause indicates to only pull records since last it executed.
### Filter
- action_type: this is set in the database and is used to determine the action to take updating the elastic search index.
### Output
- action: this comes from the database table to determine the action to take on the search index
- document_id: this is the id of the document, which is mapped to the user. This is not take from the user join statement as that will be empty in the event of a deletion.

Now in order for this to work we need to make and populate this table.

## Add Index Action Table to Database
Run `docker-compose up`

Connect to your database with your favorite app, like DBeaver.

Add a table to store the indexing actions that need to happen.

```sql
DROP TABLE IF EXISTS up_users_index_action;
CREATE TABLE up_users_index_action (
  `index_action_id` int NOT NULL AUTO_INCREMENT,
  `user_id` varchar(15) DEFAULT NULL,
  `action_type` enum('create','update','delete') DEFAULT NULL,
  `action_time` timestamp NULL DEFAULT NULL,
  PRIMARY KEY (`index_action_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
```

## Add Triggers to up_users Table

```sql
DELIMITER ;;
DROP TRIGGER IF EXISTS strapi.index_user_after_insert;;
DROP TRIGGER IF EXISTS strapi.index_user_after_update;;
DROP TRIGGER IF EXISTS strapi.index_user_after_delete;;

DELIMITER $$
CREATE TRIGGER `index_user_after_insert` AFTER INSERT ON `up_users` FOR EACH ROW
BEGIN
	INSERT INTO up_users_index_action(action_type, user_id, action_time)
	VALUES('create', NEW.id, NOW());
END$$

CREATE TRIGGER `index_user_after_update` AFTER UPDATE ON `up_users` FOR EACH ROW
BEGIN
	IF NEW.id = OLD.id THEN
		INSERT INTO up_users_index_action(action_type, user_id, action_time)
		VALUES('update', OLD.id, NOW());
	ELSE
		INSERT INTO up_users_index_action(action_type, user_id, action_time)
		VALUES('delete', OLD.id, NOW());
		INSERT INTO up_users_index_action(action_type, user_id, action_time)
		VALUES('create', NEW.id, NOW());
	END IF;
END$$

CREATE TRIGGER `index_user_after_delete` AFTER DELETE ON `up_users` FOR EACH ROW
BEGIN
	INSERT INTO up_users_index_action(action_type, user_id, action_time)
	VALUES('delete', OLD.id, NOW());
END$$
DELIMITER ;
```
### What's happening?

On these trigger events, mysql will automatically populate the index table with the appropriate actions to take against the search index. The incremental sql query will use this table to track the changes and update the search index.

# References

1. https://www.elastic.co/blog/how-to-keep-elasticsearch-synchronized-with-a-relational-database-using-logstash
1. https://towardsdatascience.com/how-to-synchronize-elasticsearch-with-mysql-ed32fc57b339
