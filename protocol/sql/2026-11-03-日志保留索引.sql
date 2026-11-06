-- ============================================
-- 2026-11-03-日志保留索引.sql
-- 日志保留清理按 created_at 分批删除
-- t_login_log / t_operation_log 已有 idx_created_at，这里补齐访问与上传日志
-- 执行前请确认已备份数据库！
-- ============================================

SET NAMES utf8mb4;

ALTER TABLE `t_visit_log` ADD INDEX `idx_created_at` (`created_at`);
ALTER TABLE `t_upload_log` ADD INDEX `idx_created_at` (`created_at`);
