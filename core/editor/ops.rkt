#lang racket

;;; editor/ops.rkt —— 纯轴算子 + 提交壳
;;;
;;;   · 纯算子：edit-op 是 (document × selections → 新值 + changes) 的纯函数 + 合并标签；
;;;             导航 / 视口都是纯函数。
;;;   · 提交壳：把纯结果写回 buffer/view（唯一可变处）。组织方式是
;;;             「文档算一次，然后 map 到该 buffer 的所有 view」。
;;;
;;; 操作是函数，组合用 compose，集合用 map；没有命令名注册表。

(require "state.rkt" "history.rkt" "query.rkt"
         "../text/document.rkt" "../text/command.rkt" "../text/rebase.rkt"
         "../text/base/point.rkt" "../text/base/selection.rkt"
         "../text/base/track.rkt" "../text/base/line.rkt" "../text/base/width.rkt"
         "../view/base/viewport.rkt")

(provide
 ;; ---------- 纯：编辑算子 ----------
 (struct-out edit-op)             ; run + 并步标签 tag
 op-type                          ; text [tag] → edit-op
 op-type-ignore-readonly          ; text [tag] → edit-op（不守只读）
 op-backspace                     ; [tag] → edit-op
 op-backspace-ignore-readonly     ; [tag] → edit-op
 op-delete                        ; [tag] → edit-op
 op-delete-ignore-readonly        ; [tag] → edit-op
 op-paste                         ; text [tag] → edit-op
 op-paste-ignore-readonly         ; text [tag] → edit-op

 ;; ---------- 提交：编辑 ----------
 buffer-edit!                     ; buffer view op [#:ensure?] → #f | (listof change)
 buffer-replace!                  ; buffer value [#:ensure? #:changes #:chunk-lines] → void
 buffer-apply-if-version!         ; buffer base-doc new-doc → applied?（CAS）
 buffer-seal!                     ; buffer → 切断后续并步

 ;; ---------- 提交：导航 ----------
 view-nav!                        ; view f [extend?] [#:ensure?] → void
 view-char-nav!                   ; view which extend? → void
 view-visual-nav!                 ; view up? extend? → void
 view-left!                       ; view [extend?] → void
 view-right!                      ; view [extend?] → void
 view-up!                         ; view [extend?] → void
 view-down!                       ; view [extend?] → void
 view-home!                       ; view [extend?] → void
 view-end!                        ; view [extend?] → void

 ;; ---------- 提交：选区 / 定位 ----------
 view-set-selections!             ; view sels [#:ensure?] → void
 view-set-point!                  ; view point → void
 view-select-all!                 ; view → void

 ;; ---------- 提交：视口 ----------
 view-ensure!                     ; view → 滚到能看见主光标
 view-ensure-cursor-position!     ; view → 滚到主光标并返回其屏幕位置 (values row col)
 view-scroll!                     ; view delta → void
 view-set-mode!                   ; view mode → void
 view-toggle-line-numbers!        ; view → void
 view-resize!                     ; view w h → void（保持锚点）
 view-set-top-line!               ; view n → void
 view-set-left-column!            ; view n → void
 view-set-anchor!                 ; view line dc → void
 view-set-anchor-point!           ; view point → void

 ;; ---------- 读：复制 ----------
 view-copy-text                   ; view → 主选区文本

 ;; ---------- 提交：历史 ----------
 buffer-undo!                     ; buffer → ok?
 buffer-redo!                     ; buffer → ok?
 buffer-clear-history!            ; buffer → void
 buffer-reset-history!            ; buffer [enabled?] → void
 buffer-set-history-enabled!)     ; buffer flag → void

;;; ================= 纯：编辑算子 =================

(struct edit-op (run tag) #:transparent)
;; run : document × selections → (values document selections changes ok?)
;; tag : any/c  并步标签（'typing 等）；#f = 不并步

(define (op-type text [tag 'typing])
  (edit-op (lambda (d s) (command-type d s text)) tag))
(define (op-type-ignore-readonly text [tag 'typing])
  (edit-op (lambda (d s) (command-type-ignore-readonly d s text)) tag))

(define (op-backspace [tag 'typing]) (edit-op command-backspace tag))
(define (op-backspace-ignore-readonly [tag 'typing]) (edit-op command-backspace-ignore-readonly tag))
(define (op-delete [tag 'typing]) (edit-op command-delete tag))
(define (op-delete-ignore-readonly [tag 'typing]) (edit-op command-delete-ignore-readonly tag))

(define (op-paste text [tag 'typing]) (edit-op (lambda (d s) (command-paste d s text)) tag))
(define (op-paste-ignore-readonly text [tag 'typing])
  (edit-op (lambda (d s) (command-paste-ignore-readonly d s text)) tag))

;;; ================= 提交：编辑 =================

;; 让视口包含主光标。
(define (view-ensure! v)
  (define p (selection-head (selections-primary (view-selections v))))
  (set-view-viewport! v (viewport-ensure (document-text (view-document v)) (view-viewport v) p)))

;; 夹到主光标，并返回夹好后它的屏幕位置（view 内坐标）。→ (values row col)
(define (view-ensure-cursor-position! v)
  (view-ensure! v)
  (view-cursor-screen-position v))

;; 把所有 view 的选区夹回合法域。
(define (buffer-clamp-views! b)
  (define t (document-text (buffer-document b)))
  (define n (track-length t))
  (for ([v (in-list (buffer-views b))])
    (set-view-selections! v (selections-clamp (view-selections v) n (curry track-line-length t)))))

;; 对一个 view 应用编辑算子；文档算一次，再 map 到所有 view。
;; 返回本次变更描述：
;;   #f          只读挡，未提交
;;   '()         提交成功但无变更
;;   (list change) 提交成功，含本次所有变更
;; 真值 = 已提交（含无变更），#f = 拒绝。
(define (buffer-edit! b v op #:ensure? [ensure? #t])
  (define h (buffer-history b))
  (define doc (history-document h))
  (define pre-sels (view-selections v))
  (define-values (doc* sels* changes ok?) ((edit-op-run op) doc pre-sels))
  (cond
    [(not ok?) #f]                                  ; 只读挡
    [(null? changes) '()]                           ; 无变更
    [else
     (define tag (edit-op-tag op))
     (define m (buffer-merge b))
     (define merge? (and tag m (equal? tag (car m)) (eq? v (cadr m))
                         (equal? pre-sels (caddr m))))
     (set-buffer-history! b (if merge? (history-merge h doc*) (history-record h doc doc*)))
     (set-buffer-merge! b (if tag (list tag v sels*) #f))
     (set-view-selections! v sels*)                 ; 发起视图：前进
     (for ([x (in-list (buffer-views b))] #:unless (eq? x v))   ; 兄弟视图：rebase
       (set-view-selections! x (selections-rebase changes (view-selections x))))
     (when ensure? (view-ensure! v))
     changes]))

;; 程序替换当前文档：不记步、封口、所有视图重定位。value = string | document。
(define (buffer-replace! b value
                         #:ensure? [ensure? #f]
                         #:changes [changes #f]
                         #:chunk-lines [chunk-lines default-chunk-lines])
  (define doc* (->document value chunk-lines))
  (define old (buffer-document b))
  (cond
    [(eq? doc* old) (void)]
    [else
     (set-buffer-history! b (history-set-current (buffer-history b) doc*))
     (set-buffer-merge! b #f)
     (if (and changes (pair? changes))
         (for ([v (in-list (buffer-views b))])
           (set-view-selections! v (selections-rebase changes (view-selections v)))
           (when ensure? (view-ensure! v)))
         (buffer-clamp-views! b))
     (void)]))

;; 异步文本写（CAS）：base-doc 未变才装，记一步。→ applied?
(define (buffer-apply-if-version! b base-doc new-doc)
  (cond
    [(not (eq? (buffer-document b) base-doc)) #f]
    [else
     (set-buffer-history! b (history-record (buffer-history b) base-doc new-doc))
     (set-buffer-merge! b #f)
     (buffer-clamp-views! b)
     #t]))

;; 封口：切断后续并步。
(define (buffer-seal! b) (set-buffer-merge! b #f))

;;; ================= 提交：导航 =================

(define (view-nav! v f [extend? #f] #:ensure? [ensure? #t])
  (set-view-selections! v ((if extend? selections-extend selections-go) (view-selections v) f))
  (when ensure? (view-ensure! v)))

(define (view-char-nav! v which extend?)
  (define t (document-text (view-document v)))
  (define f (case which
              [(left)  (lambda (p) (point-left t p))]
              [(right) (lambda (p) (point-right t p))]
              [(home)  (lambda (p) (point-home t p))]
              [(end)   (lambda (p) (point-end t p))]))
  (view-nav! v f extend?))

(define (view-visual-nav! v up? extend?)
  (define t (document-text (view-document v)))
  (define vp (view-viewport v))
  (view-nav! v (lambda (p) ((if up? point-up point-down) t vp p)) extend?))

(define (view-left! v [extend? #f])  (view-char-nav! v 'left extend?))
(define (view-right! v [extend? #f]) (view-char-nav! v 'right extend?))
(define (view-home! v [extend? #f])  (view-char-nav! v 'home extend?))
(define (view-end! v [extend? #f])   (view-char-nav! v 'end extend?))
(define (view-up! v [extend? #f])    (view-visual-nav! v #t extend?))
(define (view-down! v [extend? #f])  (view-visual-nav! v #f extend?))

;;; ================= 提交：选区 / 定位 =================

(define (view-set-selections! v sels #:ensure? [ensure? #t])
  (define t (document-text (view-document v)))
  (define n (track-length t))
  (set-view-selections! v (selections-clamp sels n (curry track-line-length t)))
  (when ensure? (view-ensure! v)))

(define (view-set-point! v p) (view-set-selections! v (selections-one (caret p))))

(define (view-select-all! v)
  (define t (document-text (view-document v)))
  (define last (sub1 (track-length t)))
  (view-set-selections! v
    (selections-one (selection (point 0 0) (point last (track-line-length t last))))))

;;; ================= 提交：视口 =================

(define (view-scroll! v delta)
  (set-view-viewport! v (viewport-scroll (document-text (view-document v)) (view-viewport v) delta)))

;; 改视口字段的公共壳：先取当前锚点，改完落回同锚。
(define (view-viewport-update! v f)
  (define t (document-text (view-document v)))
  (define-values (line dc) (viewport-anchor t (view-viewport v)))
  (set-view-viewport! v (viewport-set-anchor t (f (view-viewport v)) line dc)))

(define (view-set-mode! v mode)
  (view-viewport-update! v (lambda (vp) (viewport-set-mode vp mode))))
(define (view-toggle-line-numbers! v)
  (view-viewport-update! v (lambda (vp) (viewport-set-line-numbers vp (not (viewport-line-numbers? vp))))))
(define (view-resize! v width height)
  (view-viewport-update! v (lambda (vp) (viewport-set-size vp width height))))
(define (view-set-top-line! v n)
  (set-view-viewport! v (viewport-set-top-line (view-viewport v) n)))
(define (view-set-left-column! v n)
  (set-view-viewport! v (viewport-set-left-column (document-text (view-document v)) (view-viewport v) n)))
(define (view-set-anchor! v line dc)
  (set-view-viewport! v (viewport-set-anchor (document-text (view-document v)) (view-viewport v) line dc)))
(define (view-set-anchor-point! v p)
  (define t (document-text (view-document v)))
  (define n (track-length t))
  (define line (max 0 (min (point-line p) (sub1 n))))
  (define s (track-ref t line))
  (define col (max 0 (min (point-column p) (string-length s))))
  (set-view-viewport! v (viewport-set-anchor t (view-viewport v) line (index->display-column s col))))

;;; ================= 读：复制 =================

(define (view-copy-text v)
  (define doc (view-document v))
  (define s (selections-primary (view-selections v)))
  (define-values (a b) (selection-range s))
  (document-copy doc (point-line a) (point-column a) (point-line b) (point-column b)))

;;; ================= 提交：历史 =================

(define (buffer-undo! b)
  (define-values (h* ok?) (history-undo (buffer-history b)))
  (cond [(not ok?) #f]
        [else (set-buffer-history! b h*) (buffer-seal! b) (buffer-clamp-views! b) #t]))

(define (buffer-redo! b)
  (define-values (h* ok?) (history-redo (buffer-history b)))
  (cond [(not ok?) #f]
        [else (set-buffer-history! b h*) (buffer-seal! b) (buffer-clamp-views! b) #t]))

(define (buffer-clear-history! b)
  (set-buffer-history! b (history-clear (buffer-history b)))
  (buffer-seal! b))
(define (buffer-reset-history! b [enabled? #f])
  (set-buffer-history! b (history-set-enabled (history-clear (buffer-history b)) enabled?))
  (buffer-seal! b))
(define (buffer-set-history-enabled! b flag)
  (set-buffer-history! b (history-set-enabled (buffer-history b) flag)))
