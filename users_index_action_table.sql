
DROP TABLE IF EXISTS up_users_index_action;
CREATE TABLE up_users_index_action (
  `index_action_id` int NOT NULL AUTO_INCREMENT,
  `user_id` varchar(15) DEFAULT NULL,
  `action_type` enum('create','update','delete') DEFAULT NULL,
  `action_time` timestamp NULL DEFAULT NULL,
  PRIMARY KEY (`index_action_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
