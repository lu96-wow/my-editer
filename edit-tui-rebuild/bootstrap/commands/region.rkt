#lang racket

;;; layer  : bootstrap/commands
;;; effect : 只改 State（关闭 region 时把 view 全部 detach，不销毁 view / document）
;;;
;;; region 生命周期按 role 的 close-policy：
;;;   'hide       只从布局隐藏，region / members 保留
;;;   'delete     摘掉成员 + 删除 region + 布局剪枝
;;;   'keep-last  同 role 还有别的 region -> 按 delete；最后一块 -> 保留空 region
;;;   'ignore     拒绝（slot / 面板）

(provide close-region-command
         close-region)

(require "../../env/command.rkt"
         "../../base/id.rkt"
         "../../base/transition.rkt"
         "../../model/state.rkt"
         "../../model/workspace.rkt"
         "../../model/layout.rkt"
         "../../env/environment.rkt"
         "../../env/role.rkt"
         "../../dispatch/context.rkt"
         "util.rkt")

;;; ════════════════ 关闭 region / panel ════════════════

(define (subject-region ctx)
  (define subj (ctx-subject ctx))
  (define ws (state-workspace (ctx-state ctx)))
  (cond
    [(view-id? subj) (workspace-view-region ws subj)]
    [(region-id? subj) (workspace-region ws subj)]
    [else #f]))

(define (count-role-regions ws role)
  (for/sum ([r (in-hash-values (workspace-regions ws))]
            #:when (eq? (region-role r) role))
    1))

;; keep-last 的边界：同 role 只剩这一块。
(define (last-region-of-role? ws role)
  (= 1 (count-role-regions ws role)))

;; 把 region 里所有 view **摘出来**（保留资源），返回新 workspace + 无 effect。
(define (drop-region-views ws rid)
  (define vids (workspace-region-views ws rid))
  (values (for/fold ([w ws]) ([vid (in-list vids)])
            (workspace-detach-view w vid))
          '()))

;; 其它 region 的 active view（排除 rid）；没有 -> #f。
(define (fallback-view ws rid)
  (for/first ([r (in-hash-values (workspace-regions ws))]
              #:unless (equal? (region-key r) rid)
              #:when (view-id? (region-active r)))
    (region-active r)))

(define (close-region-command)
  (cmd (λ (ctx) (close-region ctx))))

(define (close-region ctx)
  (define s (ctx-state ctx))
  (define ws (state-workspace s))
  (define reg (subject-region ctx))
  (cond
    [(not reg) (message ctx "close-region: no region")]
    [else
     (define rid (region-key reg))
     (define role (region-role reg))
     (define policy (role-close-policy (environment-role (ctx-env ctx) role)))
     (case policy
       [(ignore)
        (message ctx "close-region: region ignores close")]

       [(hide)
        ;; 只从布局里隐藏；views / region 元数据都保留，之后可 show-region。
        (define ws1 (struct-copy workspace ws
                                 [layout (tree-hide (workspace-layout ws) rid)]))
        (define fb (fallback-view ws1 rid))
        (define ws2 (workspace-set-focus* ws1 fb #:push? #f))
        (transition (state-set-workspace s ws2) '())]

       [(delete)
        (define-values (ws1 evs) (drop-region-views ws rid))
        (define ws2 (workspace-remove-region ws1 rid))
        (define fb (fallback-view ws2 rid))
        (define ws3 (workspace-set-focus* ws2 fb #:push? #f))
        (transition (state-set-workspace s ws3) evs)]

       [(keep-last)
        (if (not (last-region-of-role? ws role))
            ;; 不是最后一块：按 delete 处理
            (let-values ([(ws1 evs) (drop-region-views ws rid)])
              (define ws2 (workspace-remove-region ws1 rid))
              (define fb (fallback-view ws2 rid))
              (define ws3 (workspace-set-focus* ws2 fb #:push? #f))
              (transition (state-set-workspace s ws3) evs))
            ;; 最后一块：清掉 views，但保留空 region 占位
            (let-values ([(ws1 evs) (drop-region-views ws rid)])
              (define fb (fallback-view ws1 rid))
              (define ws2 (workspace-set-focus* ws1 fb #:push? #f))
              (transition (state-set-workspace s ws2) evs)))]

       [else
        (message ctx (format "close-region: unknown policy ~a" policy))])]))
