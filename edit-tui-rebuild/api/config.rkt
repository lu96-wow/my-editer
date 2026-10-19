#lang racket

;;; edit-tui-rebuild/api/config.rkt —— 布局规则 API

(require "../model/config.rkt")

(provide
 ;; 类型 / 字段
 panel-rule?
 panel-rule-splittable?
 panel-rule-hideable?
 panel-rule-deletable?
 panel-rule-focusable?
 panel-rule-min-w
 panel-rule-max-w
 panel-rule-min-h
 panel-rule-max-h
 layout-config?
 layout-config-rules
 layout-config-default-rule

 ;; 构造
 make-panel-rule
 make-layout-config
 default-panel-rule
 default-config

 ;; 查询
 config-panel-rule
 config-panel-splittable?
 config-panel-hideable?
 config-panel-deletable?
 config-panel-focusable?
 panel-rule-min-size
 panel-rule-max-size)
