#lang racket

;;; layer  : bootstrap
;;; effect : 无（只是把 panel-spec 的字段转发给 effects/panel.rkt）
;;;
;;; 从“插件声明”到“实际安装”的唯一缝：
;;;
;;;   panel-spec（env/plugin.rkt，纯数据）  →  panel-install!（effects/panel.rkt）
;;;
;;; 为什么需要这一层：panel-spec 属于 env（插件贡献），而创建 engine 对象属于
;;; effects。env 不能依赖 effects，effects 也不该为了一个转发去依赖 env，
;;; 所以把“读 spec + 调安装”放在 bootstrap（装配层）。

(provide panel-spec-install!)

(require "../env/plugin.rkt"
         "../effects/panel.rkt")

;; 按 spec 装一个面板（宿主给的 region-id 决定它落在布局哪里）。
(define (panel-spec-install! engine state rid spec)
  (panel-install! engine state rid
                  #:name (panel-spec-name spec)
                  #:mode (panel-spec-mode spec)
                  #:role (panel-spec-role spec)))
