-- ============================================
-- 2026-10-26-t_outbox_event.sql
-- 新增事务性投递 outbox 表
-- 执行前请确认已备份数据库！
-- ============================================

SET NAMES utf8mb4;

CREATE TABLE IF NOT EXISTS `t_outbox_event`
(
    `id`              BIGINT       NOT NULL AUTO_INCREMENT COMMENT '主键ID',
    `event_id`        VARCHAR(64)  NOT NULL DEFAULT '' COMMENT '事件ID，消费方幂等键',
    `destination`     VARCHAR(128) NOT NULL DEFAULT '' COMMENT '目的地：exchange/topic/stream',
    `routing_key`     VARCHAR(128) NOT NULL DEFAULT '' COMMENT '事件类型',
    `message_key`     VARCHAR(255) NOT NULL DEFAULT '' COMMENT '分区/业务键',
    `headers`         TEXT COMMENT '消息头 JSON',
    `payload`         LONGBLOB     NOT NULL COMMENT '消息体',
    `status`          VARCHAR(16)  NOT NULL DEFAULT 'pending' COMMENT 'pending | publishing | published | dead',
    `retry_count`     INT          NOT NULL DEFAULT 0 COMMENT '已重试次数',
    `next_attempt_at` DATETIME(3)  NOT NULL COMMENT '下次尝试时间',
    `locked_at`       DATETIME(3)  DEFAULT NULL COMMENT 'relay 认领时间',
    `lock_token`      VARCHAR(64)  NOT NULL DEFAULT '' COMMENT 'relay 认领令牌，用于 fencing',
    `last_error`      TEXT COMMENT '最近一次错误',
    `occurred_at`     DATETIME(3)  NOT NULL COMMENT '事件发生时间',
    `created_at`      DATETIME(3)  NOT NULL COMMENT '创建时间',
    `updated_at`      DATETIME(3)  NOT NULL COMMENT '更新时间',
    `published_at`    DATETIME(3)  DEFAULT NULL COMMENT '发布时间',
    PRIMARY KEY (`id`) USING BTREE,
    UNIQUE KEY `uk_event_id` (`event_id`) USING BTREE,
    KEY `idx_status_next` (`status`, `next_attempt_at`) USING BTREE,
    KEY `idx_published` (`status`, `published_at`) USING BTREE
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_unicode_ci COMMENT ='事务性投递 outbox';
