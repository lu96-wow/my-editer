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
         "../model/state.rkt"
         "../model/workspace.rkt"
         "../model/layout.rkt"
         "../effects/panel.rkt")

;; 按 spec 装一个面板（宿主给的 region-id 决定它落在布局哪里）。
;; 创建 doc/view/region 由 effects/panel.rkt 做；spec.install 只做插件自己的
;; 初始化（写 store view-id / 展开根目录 / 记 popup region）。
(define (panel-spec-install! engine state rid spec)
  (define-values (s1 vid)
    (panel-install! engine state rid
                    #:name (panel-spec-name spec)
                    #:mode (panel-spec-mode spec)
                    #:role (panel-spec-role spec)
                    #:active? (eq? (panel-spec-placement spec) 'active)))
  (define install (panel-spec-install spec))
  (define s2
    (if (not install)
        s1
        (let ([s* (install engine s1 rid vid)])
          (unless (state? s*)
            (error 'panel-spec-install! "panel-spec install 没有返回 state：~a" s*))
          s*)))
  ;; hint 只改已有 leaf 的 dim；布局位置仍由宿主决定。
  (define hint (panel-spec-hint spec))
  (define s3
    (if (and hint (tree-find (workspace-layout (state-workspace s2)) rid))
        (state-workspace*
         s2
         (λ (ws)
           (struct-copy workspace ws
                        [layout (tree-set-dim (workspace-layout ws) rid hint)])))
        s2))
  ;; owner / key 存在时登记到 workspace.panel-index，供插件卸载 / 资源面板查找。
  (define owner (panel-spec-owner spec))
  (define key (panel-spec-key spec))
  (define s4
    (if (and owner key)
        (state-workspace*
         s3 (λ (ws) (workspace-panel-register ws owner key rid vid)))
        s3))
  (values s4 vid))
