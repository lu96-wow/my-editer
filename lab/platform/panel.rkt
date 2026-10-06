#lang racket

;;; lab-rebuild/platform/panel.rkt —— 左栏面板 provider 注册表（平台扩展点）
;;;
;;; 面板 = 左栏里显示的一个 view（文件树 / 文档列表 / …）。它就是一个只读文档，
;;; core 的渲染 / 选区 / 滚动全套照用；平台只负责把它的 vid 铺进左栏区域。
;;;
;;; 包注册一个 provider：给定上下文（根目录 / editor / 尺寸）创建 view，返回 panel 描述。
;;; 平台在装配时创建所有已注册面板，并把它的 per-did 键表加进 command-set。
;;;
;;; panel 描述：
;;;   name  : symbol              面板名（app.left 用它选显示哪个）
;;;   vid   : 面板 view
;;;   keys  : (listof keymap)     该 view 的 per-did 键表
;;;   data  : any                 包自己的状态（模型等），平台不解释
;;;   init  : (app -> void) / #f  装配完成后调用（注册钩子 / 首次刷新）

(provide (struct-out panel)
         (struct-out panel-context)
         panel-provider-register! panel-providers panel-provider-clear!)

(struct panel (name vid keys data init) #:transparent)

(struct panel-context (root ed width height) #:transparent)

(define providers '())   ; list of (panel-context -> (values ed panel))

(define (panel-provider-register! make)
  (unless (procedure? make) (error 'panel-provider-register! "需要过程，得到 ~a" make))
  (set! providers (append providers (list make)))
  make)

(define (panel-providers) providers)

;; 测试 / 重装配用。
(define (panel-provider-clear!) (set! providers '()) (void))
