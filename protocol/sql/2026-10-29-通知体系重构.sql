-- ============================================
-- 2026-10-29-通知体系重构.sql
-- 通知重建为事件 / 条目 / 投递三层：模板进代码，公告降为内容源
-- 不兼容旧数据：旧表直接删除，不迁移、不回填
-- 执行顺序：须在 2026-10-27-数据模型整改.sql 之后执行（该脚本仍引用旧的通知表）
-- 建表使用 IF NOT EXISTS，但第 1 步的 DROP 不可逆，重跑等于清空通知数据
-- 执行前请确认已备份数据库！
-- ============================================

SET NAMES utf8mb4;

-- 1. 删除旧的通知三张表
DROP TABLE IF EXISTS `t_notify_record`;
DROP TABLE IF EXISTS `t_notify_message`;
DROP TABLE IF EXISTS `t_notify_template`;

-- 2. 公告内容（承接原 t_notify_message 的职责）
CREATE TABLE IF NOT EXISTS `t_announcement` (
  `id` bigint NOT NULL AUTO_INCREMENT COMMENT 'ID',
  `title` varchar(256) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '' COMMENT '公告标题',
  `content` text COLLATE utf8mb4_unicode_ci COMMENT '公告正文（派生条目只存引用，正文以本表为准）',
  `category` varchar(50) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT 'system' COMMENT '分类：system | maintenance | update | remind',
  `level` varchar(20) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT 'info' COMMENT '等级：info | warning | error',
  `target_type` varchar(20) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT 'all' COMMENT '目标类型：all | user_ids',
  `target_ids` json DEFAULT NULL COMMENT '目标用户ID列表',
  `status` varchar(20) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT 'draft' COMMENT '状态：draft | published | revoked',
  `published_at` datetime DEFAULT NULL COMMENT '发布时间',
  `published_by` varchar(64) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '' COMMENT '发布人',
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  `updated_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '更新时间',
  PRIMARY KEY (`id`) USING BTREE,
  KEY `idx_status` (`status`) USING BTREE,
  KEY `idx_category` (`category`) USING BTREE,
  KEY `idx_published_at` (`published_at`) USING BTREE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci ROW_FORMAT=DYNAMIC COMMENT='公告内容';

-- 3. 收件箱条目
CREATE TABLE IF NOT EXISTS `t_notification` (
  `id` bigint NOT NULL AUTO_INCREMENT COMMENT 'ID',
  `event_id` bigint NOT NULL DEFAULT '0' COMMENT '通知事件ID',
  `recipient_id` varchar(64) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '' COMMENT '收件人用户ID',
  `scene` varchar(48) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '' COMMENT '场景标识',
  `object_type` varchar(32) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '' COMMENT '对象类型：article | talk | comment | user | announcement',
  `object_id` bigint NOT NULL DEFAULT '0' COMMENT '对象ID',
  `group_key` varchar(191) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '' COMMENT '展示分组键；写入时物化，不是计数',
  `dedupe_key` varchar(191) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '' COMMENT '去重键：可分组场景含触发者，不可分组场景含事件',
  `read_at` datetime DEFAULT NULL COMMENT '已读时间',
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  PRIMARY KEY (`id`) USING BTREE,
  UNIQUE KEY `uk_recipient_dedupe` (`recipient_id`,`dedupe_key`) USING BTREE,
  KEY `idx_recipient_scene_group` (`recipient_id`,`scene`,`group_key`,`created_at`) USING BTREE,
  KEY `idx_recipient_read` (`recipient_id`,`read_at`,`scene`,`group_key`) USING BTREE,
  KEY `idx_scene_read_created` (`scene`,`read_at`,`created_at`) USING BTREE,
  KEY `idx_event` (`event_id`) USING BTREE,
  KEY `idx_object` (`object_type`,`object_id`) USING BTREE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci ROW_FORMAT=DYNAMIC COMMENT='收件箱条目';

-- 4. 外部渠道投递记录
CREATE TABLE IF NOT EXISTS `t_notification_delivery` (
  `id` bigint NOT NULL AUTO_INCREMENT COMMENT 'ID',
  `notification_id` bigint NOT NULL DEFAULT '0' COMMENT '收件箱条目ID',
  `channel` varchar(16) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '' COMMENT '渠道：email | sms | push',
  `recipient` varchar(255) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '' COMMENT '收件地址：邮箱 / 手机号 / 设备端点',
  `status` varchar(16) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT 'pending' COMMENT '状态：pending | sent | failed | cancelled',
  `template_code` varchar(64) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '' COMMENT '模板编码',
  `content` text COLLATE utf8mb4_unicode_ci COMMENT '实际发送内容',
  `provider_msg_id` varchar(128) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '' COMMENT '渠道侧消息标识',
  `error_msg` varchar(512) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '' COMMENT '失败原因',
  `attempts` int NOT NULL DEFAULT '0' COMMENT '尝试次数',
  `next_retry_at` datetime DEFAULT NULL COMMENT '下次重试时间',
  `sent_at` datetime DEFAULT NULL COMMENT '发送时间',
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  `updated_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '更新时间',
  PRIMARY KEY (`id`) USING BTREE,
  UNIQUE KEY `uk_notification_channel` (`notification_id`,`channel`) USING BTREE,
  KEY `idx_status_retry` (`status`,`next_retry_at`) USING BTREE,
  KEY `idx_status_updated` (`status`,`updated_at`) USING BTREE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci ROW_FORMAT=DYNAMIC COMMENT='外部渠道投递记录';

-- 5. 通知事件（扇出工作单元）
CREATE TABLE IF NOT EXISTS `t_notification_event` (
  `id` bigint NOT NULL AUTO_INCREMENT COMMENT 'ID',
  `scene` varchar(48) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '' COMMENT '场景标识',
  `actor_id` varchar(64) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '' COMMENT '触发者用户ID；系统事件为空',
  `object_type` varchar(32) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '' COMMENT '对象类型',
  `object_id` bigint NOT NULL DEFAULT '0' COMMENT '对象ID',
  `audience_type` varchar(16) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '' COMMENT '受众类型：all | user_ids；空值非法，扇出时直接失败',
  `audience_ids` json DEFAULT NULL COMMENT '指定受众的用户ID列表',
  `payload` json DEFAULT NULL COMMENT '渲染载荷；公告事件只存内容引用',
  `status` varchar(16) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT 'pending' COMMENT '状态：pending | fanning | done | failed | terminated',
  `audience_total` bigint NOT NULL DEFAULT '0' COMMENT '受众总数，扇出开始时确定，之后不再变化',
  `cursor` bigint NOT NULL DEFAULT '0' COMMENT '扇出游标',
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  `updated_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '更新时间',
  PRIMARY KEY (`id`) USING BTREE,
  KEY `idx_status_updated` (`status`,`updated_at`) USING BTREE,
  KEY `idx_object` (`object_type`,`object_id`) USING BTREE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci ROW_FORMAT=DYNAMIC COMMENT='通知事件（扇出工作单元）';

-- 6. 通知偏好
CREATE TABLE IF NOT EXISTS `t_notification_preference` (
  `id` bigint NOT NULL AUTO_INCREMENT COMMENT 'ID',
  `user_id` varchar(64) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '' COMMENT '用户ID',
  `pref_group` varchar(32) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '' COMMENT '偏好分组：announcement | comment | like | review | security',
  `channel` varchar(16) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '' COMMENT '渠道：inbox | email | sms | push',
  `enabled` tinyint NOT NULL DEFAULT '1' COMMENT '是否接收：1 接收 0 关闭',
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  `updated_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '更新时间',
  PRIMARY KEY (`id`) USING BTREE,
  UNIQUE KEY `uk_user_group_channel` (`user_id`,`pref_group`,`channel`) USING BTREE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci ROW_FORMAT=DYNAMIC COMMENT='通知偏好';
