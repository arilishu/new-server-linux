<?php
/**
 * Plugin Name: Quiet auto-update emails
 * Description: Suppresses the "your site has updated" emails for core, plugin
 *              and theme auto-updates. Failure emails are still sent, because
 *              those need someone to act.
 *
 * Lives in mu-plugins so it cannot be disabled from wp-admin.
 */

// Core: $type is 'success', 'fail', 'critical' or 'manual'.
add_filter( 'auto_core_update_send_email', function ( $send, $type ) {
	return 'success' === $type ? false : $send;
}, 10, 2 );

/**
 * Plugins/themes: $results is a list of update result objects. Keep the email
 * only when at least one update did not succeed.
 */
function quiet_auto_update_has_failure( $results ) {
	foreach ( (array) $results as $item ) {
		if ( empty( $item->result ) || is_wp_error( $item->result ) ) {
			return true;
		}
	}
	return false;
}

add_filter( 'auto_plugin_update_send_email', function ( $enabled, $results ) {
	return $enabled && quiet_auto_update_has_failure( $results );
}, 10, 2 );

add_filter( 'auto_theme_update_send_email', function ( $enabled, $results ) {
	return $enabled && quiet_auto_update_has_failure( $results );
}, 10, 2 );
