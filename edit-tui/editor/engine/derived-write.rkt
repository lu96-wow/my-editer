#lang racket

;;; edit-tui/editor/engine/derived-write.rkt —— derived view 内容写能力
;;;
;;; 只允许 'derived view。内容写不产生 changes / history；
;;; 用户编辑 derived 走 user-write，产生 changes，由 owner 插件负责协调。
;;;
;;; 两条投影写路径：
;;;   · engine-set-derived-content!    : 兼容入口，整篇写（不带逐字符 face cache）
;;;   · engine-set-derived-projection! : 正常入口，文本 + 逐字符 face 一起安装；
;;;                                      有 doc 级基线时按行增量，否则 full fallback。
;;;
;;; derived 的投影基线按 doc-id 存。文本 / face 属性是 buffer 级的，split 出来的
;;; 兄弟 view 必须共享同一份基线，不能各自维护 per-view cache。
;;;
;;; #:base-version 是 CAS：异步投影结果不能覆盖已经变化的文本。

(require "../../../core/editor.rkt"
         "store.rkt"
         "projection-write.rkt")

(provide engine-set-derived-content!
         engine-set-derived-projection!
         engine-set-derived-cursor!)

;;; ════════════════ 投影 cache ════════════════

(define (remember-derived-projection! e did lines faces)
  (set-engine-derived-projection-cache!
   e
   (hash-set (engine-derived-projection-cache e) did
             (derived-projection lines faces))))

;; derived 的文本 / face 写完后，通用 per-view cache 不能再代表真实内容。
;; 失效即可；下一次通过旧 API 写时会自己重建。
(define (forget-derived-view-caches! e did)
  (for ([vid (in-list (or (engine-view-ids-for-doc e did) '()))])
    (set-engine-projection-cache!
     e (hash-remove (engine-projection-cache e) vid))
    (set-engine-face-track-cache!
     e (hash-remove (engine-face-track-cache e) vid))))

;;; ════════════════ 行 diff ════════════════

;; old / new : vector of line string
;; → (values old-start old-end new-start new-end)
(define (line-diff-vectors ov nv)
  (define on (vector-length ov))
  (define nn (vector-length nv))
  (define max-prefix (min on nn))
  (define p
    (let loop ([i 0])
      (cond
        [(>= i max-prefix) i]
        [(equal? (vector-ref ov i) (vector-ref nv i)) (loop (add1 i))]
        [else i])))
  (define max-suffix (- (min on nn) p))
  (define s
    (let loop ([i 0])
      (cond
        [(>= i max-suffix) i]
        [(equal? (vector-ref ov (- on 1 i))
                 (vector-ref nv (- nn 1 i)))
         (loop (add1 i))]
        [else i])))
  (values p (- on s) p (- nn s)))

(define (normalize-face-track faces)
  (for/list ([f (in-list faces)])
    (if (vector? f) f #f)))

;;; ════════════════ full / incremental ════════════════

(define (write-derived-projection-full! e did b lines faces)
  (projection-set-document-full! b lines)
  (projection-set-face-track-raw! b lines faces)
  (remember-derived-projection! e did lines faces)
  (forget-derived-view-caches! e did))

(define (write-derived-projection-incremental! e did b old lines faces)
  (define old-lines (derived-projection-lines old))
  (define old-faces (derived-projection-faces old))
  (define ov (list->vector old-lines))
  (define nv (list->vector lines))
  (define ofv (list->vector old-faces))
  (define nfv (list->vector faces))
  (define old-n (vector-length ov))
  (define new-n (vector-length nv))
  (define-values (os oe ns ne) (line-diff-vectors ov nv))
  (define text-changed? (not (and (= os oe) (= ns ne))))

  (when text-changed?
    (projection-replace-line-block!
     b old-lines os oe
     (for/list ([i (in-range ns ne)]) (vector-ref nv i))))

  ;; face 更新范围：
  ;;   · 文本变化：新变化块 + 前缀里 face 变了的行 + 后缀里 face 变了的行；
  ;;   · 文本没变：只更新 face 变了的行。
  ;; core 的文本编辑会自动平移后缀属性轨，所以后缀不需要整段重写。
  (define entries
    (cond
      [text-changed?
       (append
        (for/list ([i (in-range ns ne)])
          (cons i (vector-ref nfv i)))
        (for/list ([i (in-range 0 (min os
                                       (vector-length ofv)
                                       (vector-length nfv)))]
                   #:when (not (equal? (vector-ref ofv i)
                                       (vector-ref nfv i))))
          (cons i (vector-ref nfv i)))
        (for/list ([i (in-range 0 (- old-n oe))]
                   #:when
                   (let ([oi (- old-n 1 i)]
                         [ni (- new-n 1 i)])
                     (not (equal? (vector-ref ofv oi)
                                  (vector-ref nfv ni)))))
          (cons (- new-n 1 i)
                (vector-ref nfv (- new-n 1 i)))))]
      [else
       (for/list ([i (in-range (min (vector-length ofv)
                                    (vector-length nfv)))]
                  #:when (not (equal? (vector-ref ofv i)
                                      (vector-ref nfv i))))
         (cons i (vector-ref nfv i)))]))

  (when (pair? entries)
    (projection-set-face-lines-raw! b lines entries))
  (remember-derived-projection! e did lines faces)
  (forget-derived-view-caches! e did))

;;; ════════════════ 写入口 ════════════════

(define (engine-set-derived-content! e vid lines faces
                                     #:base-version [base-version #f])
  (and (eq? (engine-view-kind e vid) 'derived)
       (let ()
         ;; 兼容整篇入口：先破坏 derived 投影基线，下一次 projection 写走 full。
         (define did (engine-view-doc-id e vid))
         (when did (engine-forget-derived-projection! e did))
         (projection-forget-content! e vid)
         (projection-set-content! e vid lines faces
                                  #:base-version base-version))))

;; lines       : (listof string)，非空（空文档是 '("")）
;; face-track  : 与 lines 等长；每项是逐字符 vector 或 #f
;; → #t 接受（可能无实际变化）；#f 拒绝（非 derived / CAS 失败 / 形状不对）
(define (engine-set-derived-projection! e vid lines faces
                                        #:base-version [base-version #f])
  (cond
    [(not (eq? (engine-view-kind e vid) 'derived)) #f]
    [else
     (define did (engine-view-doc-id e vid))
     (define current-version (and did (engine-doc-version e did)))
     (cond
       [(not did) #f]
       [(and base-version (not (equal? base-version current-version))) #f]
       [(or (not (list? lines))
            (null? lines)
            (not (list? faces))
            (not (= (length lines) (length faces))))
        #f]
       [else
        (define b (view-buffer (engine-view-object e vid)))
        (define lines* lines)
        (define faces* (normalize-face-track faces))
        (define old (hash-ref (engine-derived-projection-cache e) did #f))
        (cond
          [(and old
                (= (length (derived-projection-lines old))
                   (length (derived-projection-faces old))))
           (write-derived-projection-incremental!
            e did b old lines* faces*)]
          [else
           (write-derived-projection-full! e did b lines* faces*)])
        #t])]))

(define (engine-set-derived-cursor! e vid line #:column [column 0])
  (and (eq? (engine-view-kind e vid) 'derived)
       (begin
         (projection-set-cursor! e vid line #:column column)
         #t)))
