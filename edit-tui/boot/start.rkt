#lang racket

;;; edit-tui-rebuild/boot/start.rkt —— 插件安装 / 同步钩子收集
;;;
;;; 顺序就是 host.plugins 的列表顺序；没有依赖解析、没有 discovery。
;;; 插件 install 允许碰 engine（boot 阶段是副作用层），返回新 state。

(require "../app/state.rkt"
         "plugin.rkt"
         "host.rkt")

(provide start-app
         install-plugin
         host-sync-hooks
         host-teardown)

(define (install-plugin host state p)
  (define install (plugin-install p))
  (if install (install host state) state))

(define (start-app host state)
  (for/fold ([state state])
            ([p (in-list (host-plugins host))])
    (install-plugin host state p)))

(define (host-sync-hooks host)
  (for/list ([p (in-list (host-plugins host))]
             #:when (plugin-sync p))
    (plugin-sync p)))

(define (host-teardown host state engine)
  (for/fold ([state state])
            ([p (in-list (reverse (host-plugins host)))])
    (define teardown (plugin-teardown p))
    (if teardown (teardown state engine) state)))
