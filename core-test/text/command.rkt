#lang racket

;; 由 core/text/command.rkt 的测试外移而来（core/ 只留实现）。
(require rackunit
       "../../core/text/command.rkt"
       "../../core/text/document.rkt"
       "../../core/text/base/point.rkt"
       "../../core/text/base/selection.rkt"
       "../../core/text/base/edit.rkt"
       "../../core/text/base/track.rkt")

(define (carets items) (selections-of items 0))

;; 多光标打字：每个光标处插入 X，光标前进
(define doc (document-open "abc\ndef"))
(define ss (carets (list (caret (point 0 1)) (caret (point 1 1)))))
(define-values (d1 s1 sp1 ok1) (command-type doc ss "X"))
(check-true ok1)
(check-equal? (document->string d1) "aXbc\ndXef")
(check-equal? (selections-items s1) (list (caret (point 0 2)) (caret (point 1 2))))

;; 多光标退格
(define-values (d2 s2 sp2 ok2) (command-backspace d1 s1))
(check-equal? (document->string d2) "abc\ndef")
(check-equal? (selections-items s2) (list (caret (point 0 1)) (caret (point 1 1))))

;; 多光标前向删除
(define-values (d3 s3 sp3 ok3) (command-delete d2 s2))
(check-equal? (document->string d3) "ac\ndf")
(check-equal? (selections-items s3) (list (caret (point 0 1)) (caret (point 1 1))))

;; 选区（非空）替换
(define sel (selections-of (list (selection (point 0 0) (point 0 2))
                                 (selection (point 1 1) (point 1 3))) 0))
(check-equal? (document->string (let-values ([(dz sz spz okz) (command-type doc sel "Z")]) dz))
              "Zc\ndZ")
;; 删整段选区
(check-equal? (document->string (let-values ([(dd sd spd okd) (command-delete doc sel)]) dd))
              "c\nd")
(check-equal? (selections-items (let-values ([(dd sd spd okd) (command-delete doc sel)]) sd))
              (list (caret (point 0 0)) (caret (point 1 1))))

;; 守：其中一条落在只读格 → 整体拒绝
(define ro (document-readonly-fill doc 0 1 0 2 #t))
(define-values (d4 s4 sp4 ok4) (command-type ro ss "X"))
(check-false ok4)
(check-eq? d4 ro)
(check-eq? s4 ss)
;; 程序版绕过
(define-values (d5 s5 sp5 ok5) (command-type-ignore-readonly ro ss "X"))
(check-true ok5)
(check-equal? (document->string d5) "aXbc\ndXef")

;; 多光标 + 跨行/宽字符：上/下导航后再打字（简单覆盖）
(define doc2 (document-open "中a\nbc"))
(define-values (d6 s6 sp6 ok6) (command-type doc2 (carets (list (caret (point 0 2)) (caret (point 1 2)))) "!"))
(check-equal? (document->string d6) "中a!\nbc!")

;; 回归：多光标 + 多字符插入，右侧插入不得把左侧光标多推
(define doc3 (document-open "abcdefgh"))
(define-values (d7 s7 sp7 ok7) (command-type doc3 (carets (list (caret (point 0 1)) (caret (point 0 3)))) "XXXXX"))
(check-equal? (document->string d7) "aXXXXXbcXXXXXdefgh")
(check-equal? (selections-items s7) (list (caret (point 0 6)) (caret (point 0 13))))

;; ---------- 富粘贴（多光标 + 属性一起走） ----------
(define cp-src (document-highlight-fill (document-open "H\ni") 0 0 0 1 'kw))
(define cp (document-copy cp-src 0 0 1 1))            ; "H\ni"，高亮 H
(define pd (document-open "ab\ncd"))
(define pss (carets (list (caret (point 0 1)) (caret (point 1 1)))))
(define-values (pd1 ps1 psp1 pok1) (command-paste pd pss cp))
(check-true pok1)
(check-equal? (document->string pd1) "aH\nib\ncH\nid")
(check-equal? (track-ref (document-highlight pd1) 0) (vector #f 'kw))   ; 粘贴的 H 带高亮
(check-equal? (track-ref (document-highlight pd1) 2) (vector #f 'kw))
(check-equal? (selections-items ps1) (list (caret (point 1 1)) (caret (point 3 1))))
;; 空剪贴板可粘：什么都不插
(define-values (pd0 ps0 psp0 pok0) (command-paste pd pss (clipboard-of-text "")))
(check-equal? (document->string pd0) "ab\ncd")
;; 守：其中一条落在只读格 → 整体拒绝
(define pro (document-readonly-fill pd 0 1 0 2 #t))
(check-false (let-values ([(d s sp ok) (command-paste pro pss cp)]) ok))

(displayln "command.rkt: all tests passed")
