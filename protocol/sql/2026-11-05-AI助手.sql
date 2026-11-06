-- ============================================
-- 2026-11-05-AI助手.sql
-- 新增 AI 会话、消息与文章分块三张表
-- 分块表带中文 ngram 全文索引，供 AI 助手检索公开文章
-- 执行前请确认已备份数据库！
-- ============================================

SET NAMES utf8mb4;

CREATE TABLE IF NOT EXISTS `t_ai_session` (
  `id` bigint NOT NULL AUTO_INCREMENT COMMENT '主键',
  `user_id` varchar(64) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '' COMMENT '所属用户',
  `title` varchar(128) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '' COMMENT '标题',
  `model` varchar(64) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '' COMMENT '模型',
  `message_count` int NOT NULL DEFAULT '0' COMMENT '消息条数',
  `last_message_at` datetime DEFAULT NULL COMMENT '最近消息时间',
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  `updated_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '更新时间',
  PRIMARY KEY (`id`) USING BTREE,
  KEY `idx_user` (`user_id`,`last_message_at`) USING BTREE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci ROW_FORMAT=DYNAMIC COMMENT='AI会话';

CREATE TABLE IF NOT EXISTS `t_ai_message` (
  `id` bigint NOT NULL AUTO_INCREMENT COMMENT '主键',
  `session_id` bigint NOT NULL DEFAULT '0' COMMENT '会话id',
  `role` varchar(16) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '' COMMENT '角色：user/assistant',
  `content` longtext COLLATE utf8mb4_unicode_ci NOT NULL COMMENT '正文',
  `prompt_tokens` int NOT NULL DEFAULT '0' COMMENT '提示词token数',
  `completion_tokens` int NOT NULL DEFAULT '0' COMMENT '生成token数',
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  PRIMARY KEY (`id`) USING BTREE,
  KEY `idx_session` (`session_id`,`id`) USING BTREE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci ROW_FORMAT=DYNAMIC COMMENT='AI会话消息';

CREATE TABLE IF NOT EXISTS `t_article_chunk` (
  `id` bigint NOT NULL AUTO_INCREMENT COMMENT '主键',
  `article_id` bigint NOT NULL DEFAULT '0' COMMENT '所属文章id',
  `article_title` varchar(64) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '' COMMENT '文章标题',
  `ordinal` int NOT NULL DEFAULT '0' COMMENT '分块序号',
  `heading` varchar(255) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '' COMMENT '标题路径',
  `content` text COLLATE utf8mb4_unicode_ci NOT NULL COMMENT '片段正文',
  `summary` varchar(512) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '' COMMENT '截断摘要',
  `content_hash` char(64) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '' COMMENT '内容摘要，用于判断是否变化',
  `updated_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '更新时间',
  PRIMARY KEY (`id`) USING BTREE,
  KEY `idx_article` (`article_id`) USING BTREE,
  FULLTEXT KEY `ft_content` (`article_title`,`heading`,`content`) WITH PARSER ngram
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci ROW_FORMAT=DYNAMIC COMMENT='文章分块';
