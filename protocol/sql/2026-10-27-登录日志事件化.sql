-- ============================================
-- 2026-10-27-登录日志事件化.sql
-- 登录日志改为事件表：登出不再回写登录行，而是追加一条登出事件
-- 执行前请确认已备份数据库！
-- ============================================

SET NAMES utf8mb4;

-- 1. 新增事件字段
ALTER TABLE `t_login_log`
    ADD COLUMN `event_type` TINYINT NOT NULL DEFAULT 1 COMMENT '事件类型 1登录 2登出' AFTER `device_id`,
    ADD COLUMN `logout_type` VARCHAR(32) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '' COMMENT '登出类型：手动登出/超时/强制下线（登录事件为空）' AFTER `login_type`;

-- 2. 历史会话补登出事件（原先记录在 logout_at 上）
INSERT INTO `t_login_log` (`user_id`, `device_id`, `event_type`, `logout_type`, `status`, `created_at`, `updated_at`)
SELECT `user_id`, `device_id`, 2, 'session closed', 1, `logout_at`, `logout_at`
FROM `t_login_log`
WHERE `logout_at` IS NOT NULL;

-- 3. 回写字段不再保留
ALTER TABLE `t_login_log`
    DROP COLUMN `logout_at`;
