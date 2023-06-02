
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