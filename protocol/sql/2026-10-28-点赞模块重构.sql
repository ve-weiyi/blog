-- ============================================
-- 2026-10-28-点赞模块重构.sql
-- 点赞以 t_like 为唯一状态：点赞数与是否已赞都在读取时派生
-- 执行前请确认已备份数据库！
-- ============================================

SET NAMES utf8mb4;

-- 1. 去掉三张目标表上的计数列（改为由 t_like 聚合得出）
ALTER TABLE `t_article` DROP COLUMN `like_count`;
ALTER TABLE `t_talk` DROP COLUMN `like_count`;
ALTER TABLE `t_comment` DROP COLUMN `like_count`;

-- 2. 点赞表索引：按页判定是否已赞、按时间列出某人的点赞
ALTER TABLE `t_like`
    DROP INDEX `idx_user`,
    ADD INDEX `idx_user_target` (`user_id`, `target_type`, `target_id`),
    ADD INDEX `idx_user_created` (`user_id`, `target_type`, `created_at`);
