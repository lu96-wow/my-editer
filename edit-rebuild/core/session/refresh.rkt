#lang racket

;;; edit-rebuild/core/session/refresh.rkt —— 面内容刷新
;;;
;;; 局部问题：渲染前把每个「有内容生成函数」的面刷新一遍。面的 content 是
;;;   session -> (or/c document #f)     #f = 本次不刷新
;;; 生成出文档就装回该面的 vid（走 adapter 的写原语）。
;;;
;;; 状态窗口（状态行 / 缓冲区 / 文件树 / 日志）都靠这一处刷新，内容没变时由各面的
;;; content 自己返回 #f（避免每帧重装）。

(require "session.rkt"
         "adapter.rkt"
         "../surface/surface.rkt")

(provide session-refresh)

(define (session-refresh s)
  (for/fold ([s s]) ([sf (in-list (session-surfaces s))])
    (define f (surface-content sf))
    (cond
      [(not f) s]
      [else
       (define doc (f s))
       (if doc (session-ed-assign! s (surface-vid sf) doc) s)])))
