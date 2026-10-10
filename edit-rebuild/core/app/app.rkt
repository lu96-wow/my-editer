#lang racket

;;; edit-rebuild/core/app/app.rkt —— 内核组装：空编辑区 + 注入的插件
;;;
;;; 内核**不认识任何具体插件**（连状态窗口都没有）。插件（plugin-spec 列表）由外部注入，
;;; 每个插件自行登记面板 / handler / 键；内核按面的 region 把它们归进骨架。
;;;
;;;   (app-session #:plugins (enabled-plugins))
;;;   (app-session #:layout layout-top)

(require "../geometry/layout.rkt"
         "../focus.rkt"
         "../ids.rkt"
         "../config/layout.rkt"
         "../session/session.rkt"
         "../session/adapter.rkt"
         "../session/focus.rkt"
         "../session/layout.rkt"
         "../session/plugin.rkt"
         "../extension/spec.rkt"
         "../command/keys.rkt")

(provide app-session)

(define (app-session [w 80] [h 24]
                     #:layout [layout layout-left]
                     #:plugins [plugins '()])
  ;; 装配注入：打开文件时的文档绑定规则（把注入的 face 插件绑到文档）。
  (define s0 (session-set-rules
              (session-blank w h (list base-keys))
              (list (face-plugin-rule (plugin-face-plugins plugins)))))
  ;; 装插件：各自登记面 / handler / 键。
  (define s1 (install-plugins s0 plugins))
  ;; 每个 region 初始只显示第一个面（同区域互斥）。
  (define s1* (session-init-region-visibility s1))
  ;; 按面的 region 归位，装配骨架。
  (define s2 (session-assemble s1* layout (session-region-bindings s1*)))
  ;; 初始焦点：首个停靠面（优先 side）。
  (session-set-focus s2 (focus-set (session-focus s2) (session-first-panel-vid s2))))
