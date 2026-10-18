#lang racket

;;; runtime/worker.rkt —— 后台 worker（独立 place = 独立进程）
;;;
;;; layer  : runtime
;;; effect : **多进程**：起一个 place 跑 plugins/worker.rkt，收发可序列化消息
;;;
;;; 为什么多进程：模块导出 / 文档查询 / 全量扫描这类**纯计算或只读查询**会变慢。
;;; 它们不碰 State / core，只吃可序列化 payload、吐可序列化 result：
;;;
;;;   提交: (vector 'job  job-id kind payload)
;;;   回来: (vector 'done job-id result)   → (internal-event 'job-done (list job-id result))
;;;
;;; **一个 place = 一条队列**：同一时刻只跑一个 job，按提交顺序执行。
;;; 这正是多个高亮插件要的语义（前景层 / 背景层按顺序算，结果按层序合成，不打架）。
;;;
;;; 降级：place 起不来（已在 place 里 / 平台不支持）→ 返回 #f，runtime 退化成
;;; **同步内联**执行（同一个 service-run，只是不换进程）。
;;;
;;; 结果只回 inbox，不改 State —— worker 不破坏 `world-step` 的纯粹性。
;;; 服务异常被包成 (vector 'error msg) 作为 result，仍按 job-done 回投；
;;; 插件应把非预期 result 当成失败并清 pending。

(provide (struct-out worker)
         worker-entry-path
         worker-known-service-kinds
         worker-start!
         worker-submit!
         worker-stop!)

(require racket/match
         racket/async-channel
         (prefix-in app: "../base/event.rkt"))

(struct worker (place-ch out) #:transparent)
;; place-ch : place-channel（双向：提交 job / 收结果）
;; out      : thread（把 place 的结果搬进 inbox）

;; 本模块所在目录 → ../plugins/worker.rkt（place 里 dynamic-require 它）
(define (worker-entry-path)
  (define here
    (resolved-module-path-name
     (module-path-index-resolve
      (variable-reference->module-path-index (#%variable-reference)))))
  (path->string (simplify-path (build-path (path-only (path->complete-path here))
                                           ".." "plugins" "worker.rkt"))))

;; worker 实现的 service kind 表（plugins/worker.rkt 的 service-kinds）。
;; 只在 startup 校验 / 调试时用；不在热路径。
(define (worker-known-service-kinds)
  (dynamic-require (string->path (worker-entry-path)) 'service-kinds))

;; 起一个 worker；失败 → #f（调用方走同步降级）。
(define (worker-start! inbox)
  (define path (worker-entry-path))
  (define ch
    (with-handlers ([exn:fail? (λ (_) #f)])
      (place
       ch
       (let* ([entry (place-channel-get ch)]
              [run (dynamic-require (string->path entry) 'service-run)])
         (let loop ()
           (define msg (place-channel-get ch))
           (match msg
             [(vector 'job id kind payload)
              (define result
                (with-handlers ([exn:fail? (λ (e) (vector 'error (exn-message e)))])
                  (run kind payload)))
              (place-channel-put ch (vector 'done id result))
              (loop)]
             [(vector 'stop) (void)]
             [_ (loop)]))))))
  (cond
    [(not ch) #f]
    [else
     (place-channel-put ch path)
     (define out
       (thread
        (λ ()
          (let loop ()
            (define msg (place-channel-get ch))
            (match msg
              [(vector 'done id result)
               (async-channel-put inbox (app:internal-event 'job-done (list id result)))
               (loop)]
              [_ (void)])))))
     (worker ch out)]))

(define (worker-submit! w job-id kind payload)
  (when w
    (place-channel-put (worker-place-ch w) (vector 'job job-id kind payload)))
  (void))

(define (worker-stop! w)
  (when w
    (with-handlers ([exn:fail? (λ (_) #f)])
      (place-channel-put (worker-place-ch w) (vector 'stop))))
  (void))
