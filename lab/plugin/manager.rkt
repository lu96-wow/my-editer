#lang racket

(require "../../core/editor.rkt"
         "api.rkt"
         "runner.rkt")

;;; lab/plugin/manager.rkt —— 插件管理器：按版本 token 同步 + 调度 + 合并 + 写回
;;;
;;; 每个 document 版本一个 **token**（主进程分配，弱表 doc→token）。
;;; worker 和同步 runner 按 (did, token) 缓存影子；结果也按 token 缓存。
;;;
;;; 于是：
;;;   · 文本编辑：发增量（change! from→to），只对没算过的 token 派活；
;;;   · **undo/redo：回到旧 token，影子还在、结果还在 → 不发文本、不重算、不写属性**
;;;     （属性本来就随 document 值存在 box 里，恢复出来的就是算好的）。
;;;
;;; 版本表每个 did 保留最近 history-bound 个 token，超界淘汰（通知 runner drop + 清缓存）。
;;;
;;; 版本闸门：结果回来时 token 必须还是当前文档的 token，否则丢——迟到结果不会写错版本。

(provide (struct-out manager)
         make-manager
         manager-plugins manager-runner
         manager-note-change!
         manager-sync! manager-poll! manager-forget! manager-source manager-stop!)

(define history-bound 64)

(struct manager (plugins runner tokens next-token tracked pending jobs results next-tag)
  #:mutable #:transparent)
;; plugins     : (listof plugin)
;; runner      : runner
;; tokens      : weak-hasheq document -> token
;; next-token  : exact-nonnegative-integer
;; tracked     : hash did -> (listof token)               已发过影子的版本，最新在前
;; pending     : hash did -> (listof edit)               本 tick 记下、还没发出的增量
;;               edit = (list l0 c0 l1 c1 inserted)；同一编辑前坐标系、互不重叠；
;;               一个 tick 最多一条编辑命令 → 一批
;; jobs        : hash tag -> (list did token name)
;; results     : hash did -> (listof (cons token (hash name fills)))   最新在前
;; next-tag    : exact-nonnegative-integer

(define (make-manager plugins runner)
  (manager plugins runner (make-weak-hasheq) 0
           (make-hash) (make-hash) (make-hash) (make-hash) 0))

(define (manager-source m) (runner-source (manager-runner m)))
(define (manager-stop! m) (runner-stop! (manager-runner m)))

;; 版本 → token（同一个 document 值永远同一个 token）。
(define (token-of m doc)
  (or (hash-ref (manager-tokens m) doc #f)
      (let ([t (manager-next-token m)])
        (set-manager-next-token! m (add1 t))
        (hash-set! (manager-tokens m) doc t)
        t)))

;; 编辑命令送来一批增量（同一编辑前坐标系、互不重叠）。
(define (manager-note-change! m did edits)
  (when (pair? edits)
    (hash-set! (manager-pending m) did edits)))

;; infos : (listof (list did path)) —— app 只把「真实文件」传进来。
(define (manager-sync! m ed infos)
  (for ([info (in-list infos)])
    (match-define (list did path) info)
    (define doc (editor-document-handle ed did))
    (define token (token-of m doc))
    (define tracked (hash-ref (manager-tracked m) did '()))
    (unless (eqv? token (and (pair? tracked) (car tracked)))
      (define edits (hash-ref (manager-pending m) did '()))
      (hash-remove! (manager-pending m) did)
      (cond
        [(memv token tracked) (void)]                       ; 旧版本：影子还在，什么都不用发
        [(and (pair? tracked) (pair? edits))
         (runner-change! (manager-runner m) did (car tracked) token edits)]
        [else
         (runner-open! (manager-runner m) did token (document->string doc))])
      ;; 版本表：新 token 置顶；超界淘汰 → runner drop + 清结果缓存。
      (define all (cons token (remove* (list token) tracked)))
      (define kept (take all (min (length all) history-bound)))
      (define evicted (drop all (length kept)))
      (hash-set! (manager-tracked m) did kept)
      (for ([t (in-list evicted)]) (runner-drop! (manager-runner m) did t))
      (when (pair? evicted)
        (hash-set! (manager-results m) did
                   (for/list ([e (in-list (hash-ref (manager-results m) did '()))]
                              #:unless (memv (car e) evicted))
                     e)))
      ;; 只给「这个 token 还没算过」的插件派活；undo/redo 命中缓存 → 不派。
      (define cached (assv token (hash-ref (manager-results m) did '())))
      (for ([p (in-list (manager-plugins m))])
        (unless (and cached (hash-has-key? (cdr cached) (plugin-name p)))
          (define tag (manager-next-tag m))
          (set-manager-next-tag! m (add1 tag))
          (hash-set! (manager-jobs m) tag (list did token (plugin-name p)))
          (runner-submit! (manager-runner m) tag (plugin-name p) did token path))))))

(define (manager-poll! m ed)
  (define changed (mutable-set))
  (for ([msg (in-list (runner-poll! (manager-runner m)))])
    (match-define (list tag name fills) msg)
    (define job (hash-ref (manager-jobs m) tag #f))
    (when job
      (hash-remove! (manager-jobs m) tag)
      (match-define (list did token _name) job)
      (when (memv did (editor-document-id-list ed))        ; 文档还开着
        (when (eqv? token (token-of m (editor-document-handle ed did)))  ; 版本没变
          (put-result! m did token name fills)
          (set-add! changed did)))))
  (for ([did (in-list (set->list changed))])
    (apply-results! m ed did))
  (set->list changed))

(define (put-result! m did token name fills)
  (define rs (hash-ref (manager-results m) did '()))
  (define entry (assv token rs))
  (cond
    [entry (hash-set! (cdr entry) name fills)]
    [else (hash-set! (manager-results m) did
                     (cons (cons token (make-hash (list (cons name fills)))) rs))]))

;; 把该 token 的所有插件结果合并写入高亮轨。
(define (apply-results! m ed did)
  (define doc (editor-document-handle ed did))
  (define token (token-of m doc))
  (define cached (assv token (hash-ref (manager-results m) did '())))
  (define merged
    (append* (for/list ([p (in-list (sort (manager-plugins m) < #:key plugin-priority))])
               (define r (and cached (hash-ref (cdr cached) (plugin-name p) #f)))
               (if r r '()))))
  (editor-document-handle-set-highlight! doc #f)
  (editor-document-handle-highlight-batch! doc merged))

(define (manager-forget! m did)
  (hash-remove! (manager-tracked m) did)
  (hash-remove! (manager-pending m) did)
  (hash-remove! (manager-results m) did)
  (runner-close! (manager-runner m) did))
