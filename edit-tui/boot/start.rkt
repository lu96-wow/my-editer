#lang racket

;;; edit-tui-rebuild/boot/start.rkt —— 插件安装 / teardown
;;;
;;; 顺序就是 host.plugins 的列表顺序；没有依赖解析、没有 discovery。
;;; 插件 install 允许碰 engine（boot 阶段是副作用层），返回新 state。
;;; 每帧的 sync / analysis / projection 由 boot 的显式循环决定，不走插件回调。

(require racket/list
         "../app/state.rkt"
         "plugin.rkt"
         "host.rkt")

(provide start-app
         install-plugin
         host-services
         host-teardown)

(define (install-plugin host state p)
  (define install (plugin-install p))
  (if install (install host state) state))

(define (start-app host state)
  (for/fold ([state state])
            ([p (in-list (host-plugins host))])
    (install-plugin host state p)))

;; 插件 services 按安装顺序汇总；host 把它们交给 run-app。
(define (host-services host)
  (append* (for/list ([p (in-list (host-plugins host))])
             (plugin-services p))))

(define (host-teardown host state engine)
  (for/fold ([state state])
            ([p (in-list (reverse (host-plugins host)))])
    (define teardown (plugin-teardown p))
    (if teardown (teardown state engine) state)))
