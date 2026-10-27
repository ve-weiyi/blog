-- ============================================
-- 2026-10-27-数据模型整改.sql
-- 对齐《数据模型》：索引、类型宽度、列名、JSON 列、点赞明细表
-- 执行前请确认已备份数据库！
-- MySQL 8 不支持 ADD/DROP INDEX IF NOT EXISTS，本脚本按当前线上状态一次性执行
-- ============================================

SET NAMES utf8mb4;

-- ============================================
-- 1. 数据归一化（必须在改类型之前）
-- ============================================

-- 留言用户 id 的历史笔误：'0' 归一为空串
UPDATE `t_message` SET `user_id` = '' WHERE `user_id` = '0';

-- JSON 列：空串改为 JSON null，否则 MODIFY JSON 会因非法文本失败
UPDATE `t_user` SET `info` = 'null' WHERE `info` IS NULL OR `info` = '';
UPDATE `t_talk` SET `images` = 'null' WHERE `images` IS NULL OR `images` = '';
UPDATE `t_page` SET `carousel_covers` = 'null' WHERE `carousel_covers` IS NULL OR `carousel_covers` = '';

-- 通知目标：逗号分隔串转为 JSON 数组
UPDATE `t_notify_message`
SET `target_ids` = JSON_ARRAY(`target_ids`)
WHERE `target_ids` IS NOT NULL AND `target_ids` <> '' AND JSON_VALID(`target_ids`) = 0;

UPDATE `t_notify_message` SET `target_ids` = 'null' WHERE `target_ids` IS NULL OR `target_ids` = '';

-- 操作耗时：历史值为时长文本，取数字部分作为毫秒
UPDATE `t_operation_log`
SET `cost` = CAST(REGEXP_SUBSTR(`cost`, '[0-9]+') AS UNSIGNED)
WHERE `cost` <> '' AND `cost` NOT REGEXP '^[0-9]+$';

-- 日快照：空日期回填为创建日期
UPDATE `t_daily_stats`
SET `date` = DATE_FORMAT(`created_at`, '%Y-%m-%d')
WHERE `date` = '' OR `date` IS NULL;

-- ============================================
-- 2. 列类型
-- ============================================

-- 线上库缺失的列：评论审核状态（代码与 DDL 均在用）
ALTER TABLE `t_comment`
    ADD COLUMN `is_review` TINYINT NOT NULL DEFAULT 0 COMMENT '审核状态：0-未审核 1-已通过' AFTER `status`;

ALTER TABLE `t_user`
    MODIFY `status` TINYINT NOT NULL DEFAULT 0 COMMENT '账号状态：0-正常 1-禁用 2-注销';

ALTER TABLE `t_comment`
    MODIFY `reply_user_id` VARCHAR(64) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '' COMMENT '评论回复用户id',
    MODIFY `type` TINYINT NOT NULL DEFAULT 0 COMMENT '评论类型 1.文章 2.友链 3.说说',
    MODIFY `status` TINYINT NOT NULL DEFAULT 0 COMMENT '状态 0.正常 1.已编辑 2.已删除';

ALTER TABLE `t_chat`
    MODIFY `status` TINYINT NOT NULL DEFAULT 0 COMMENT '状态:0正常 1编辑 2撤回 3删除';

ALTER TABLE `t_message`
    MODIFY `user_id` VARCHAR(64) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '' COMMENT '用户id',
    MODIFY `device_id` VARCHAR(64) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '' COMMENT '终端id',
    MODIFY `status` TINYINT NOT NULL DEFAULT 0 COMMENT '状态:0正常 1编辑 2撤回 3删除';

ALTER TABLE `t_login_log`
    MODIFY `status` TINYINT NOT NULL DEFAULT 1 COMMENT '登录状态：0-失败 1-成功';

ALTER TABLE `t_operation_log`
    MODIFY `response_status` SMALLINT NOT NULL DEFAULT 0 COMMENT '响应状态码',
    MODIFY `cost` INT NOT NULL DEFAULT 0 COMMENT '耗时（ms）';

ALTER TABLE `t_menu`
    MODIFY `rank` INT NOT NULL DEFAULT 0 COMMENT '排序';

ALTER TABLE `t_upload_log`
    MODIFY `file_md5` CHAR(32) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '' COMMENT '文件md5值';

ALTER TABLE `t_user`
    MODIFY `info` JSON DEFAULT NULL COMMENT '用户信息';

ALTER TABLE `t_talk`
    MODIFY `images` JSON DEFAULT NULL COMMENT '图片';

ALTER TABLE `t_page`
    MODIFY `carousel_covers` JSON DEFAULT NULL COMMENT '轮播图片列表';

ALTER TABLE `t_notify_message`
    MODIFY `target_ids` JSON DEFAULT NULL COMMENT '目标用户ID列表';

ALTER TABLE `t_daily_stats`
    MODIFY `date` DATE NOT NULL COMMENT '统计日期 YYYY-MM-DD';

-- ============================================
-- 3. 列改名（索引随之指向新列，再改索引名）
-- ============================================

ALTER TABLE `t_config`
    CHANGE COLUMN `key` `config_key` VARCHAR(32) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '' COMMENT '关键词';

ALTER TABLE `t_config`
    RENAME INDEX `uk_key` TO `uk_config_key`;

-- ============================================
-- 4. 索引
-- ============================================

-- 索引名与 DDL 对齐（定义不变）
ALTER TABLE `t_api`
    RENAME INDEX `idx_path_method` TO `idx_path_method_name`;

-- 模板身份改为场景 + 渠道
ALTER TABLE `t_notify_template`
    DROP INDEX `uk_code_channel`,
    ADD UNIQUE KEY `uk_scene_channel` (`scene`,`channel`) USING BTREE;

-- 角色标识唯一
ALTER TABLE `t_role`
    ADD UNIQUE KEY `uk_role_key` (`role_key`) USING BTREE;

-- 无查询支撑的索引
ALTER TABLE `t_user`
    DROP INDEX `idx_created_at`,
    DROP INDEX `idx_deleted_at`;

-- 内容列表
ALTER TABLE `t_article`
    ADD KEY `idx_delete_status_id` (`is_delete`,`status`,`id`) USING BTREE,
    ADD KEY `idx_category_delete_status_id` (`category_id`,`is_delete`,`status`,`id`) USING BTREE;

ALTER TABLE `t_comment`
    ADD KEY `idx_review_created` (`is_review`,`created_at`) USING BTREE,
    ADD KEY `idx_type_topic_created` (`type`,`topic_id`,`created_at`) USING BTREE;

ALTER TABLE `t_photo`
    ADD KEY `idx_album` (`album_id`) USING BTREE;

-- 鉴权与关联
ALTER TABLE `t_role_menu`
    ADD KEY `idx_role` (`role_id`) USING BTREE;

ALTER TABLE `t_role_api`
    ADD KEY `idx_role` (`role_id`) USING BTREE;

ALTER TABLE `t_user_role`
    ADD KEY `idx_user` (`user_id`) USING BTREE,
    ADD KEY `idx_role` (`role_id`) USING BTREE;

-- 日志筛选
ALTER TABLE `t_operation_log`
    ADD KEY `idx_created_at` (`created_at`) USING BTREE,
    ADD KEY `idx_user_id` (`user_id`) USING BTREE;

-- ============================================
-- 5. 点赞明细
-- ============================================

CREATE TABLE IF NOT EXISTS `t_like`
(
    `id`          BIGINT      NOT NULL AUTO_INCREMENT COMMENT '主键',
    `target_type` TINYINT     NOT NULL DEFAULT 0 COMMENT '目标类型 1.文章 2.说说 3.评论',
    `target_id`   BIGINT      NOT NULL DEFAULT 0 COMMENT '目标id',
    `user_id`     VARCHAR(64) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '' COMMENT '点赞用户id',
    `created_at`  DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
    PRIMARY KEY (`id`) USING BTREE,
    UNIQUE KEY `uk_target_user` (`target_type`,`target_id`,`user_id`) USING BTREE,
    KEY `idx_user` (`user_id`) USING BTREE
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_unicode_ci COMMENT ='点赞记录';

-- ============================================
-- 6. 执行后校验
-- ============================================

SELECT TABLE_NAME, INDEX_NAME, GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX) AS cols
FROM information_schema.STATISTICS
WHERE TABLE_SCHEMA = DATABASE()
  AND INDEX_NAME <> 'PRIMARY'
GROUP BY TABLE_NAME, INDEX_NAME
ORDER BY TABLE_NAME, INDEX_NAME;
